//
//  DTXSocketConnection.m
//  MyCoolNetworkServer
//
//  Created by Leo Natan (Wix) on 18/07/2017.
//  Copyright © 2017 LeoNatan. All rights reserved.
//

#import "DTXSocketConnection.h"

@interface DTXSocketConnection () <NSStreamDelegate>

@end

@implementation DTXSocketConnection
{
	dispatch_queue_t _workQueue;
	NSInputStream* _inputStream;
	NSOutputStream* _outputStream;
	
	BOOL _inputWaitingForHeader;
	BOOL _inputWaitingForData;
	uint64_t _inputTotalDataLength;
	uint8_t* _inputBytes;
	uint64_t _inputCurrentBytesLength;
	BOOL _inputPendingClose;
	
	NSMutableArray<NSData*>* _outputPendingDatasToBeWritten;
	BOOL _outputWaitingForHeader;
	BOOL _outputWaitingForData;
	NSData* _outputData;
	uint64_t _outputCurrentBytesLength;
	BOOL _outputPendingClose;
	
	NSMutableArray<void (^)(NSData *data, NSError *error)>* _pendingReads;
	NSMutableArray<void (^)(NSError *error)>* _pendingWrites;
}

- (instancetype)initWithInputStream:(NSInputStream*)inputStream outputStream:(NSOutputStream*)outputStream queue:(nullable dispatch_queue_t)queue
{
	NSAssert(inputStream != nil && outputStream != nil, @"Streams must not be nil.");
	NSAssert(inputStream.streamStatus == NSStreamStatusNotOpen && outputStream.streamStatus == NSStreamStatusNotOpen, @"Streams must not be opened.");
	
	self = [super init];
	
	if(self)
	{
		_workQueue = queue ?: dispatch_get_main_queue();
		_inputStream = inputStream;
		_outputStream = outputStream;
		
		[self _commonInit];
	}
	
	return self;
}

- (instancetype)initWithHostName:(NSString*)hostName port:(NSInteger)port queue:(nullable dispatch_queue_t)queue
{
	NSAssert(hostName != nil, @"Host name must not be nil.");
	
	self = [super init];
	
	if(self)
	{
		CFReadStreamRef readStream;
		CFWriteStreamRef writeStream;
		CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)hostName, (UInt32)port, &readStream, &writeStream);
		
		_inputStream = CFBridgingRelease(readStream);
		_outputStream = CFBridgingRelease(writeStream);
		
		[self _commonInit];
	}
	
	return self;
}

- (void)_commonInit
{
	_pendingReads = [NSMutableArray new];
	_pendingWrites = [NSMutableArray new];
}

- (void)open
{
	dispatch_async(_workQueue, ^{
		NSAssert(_inputStream.streamStatus == NSStreamStatusNotOpen && _outputStream.streamStatus == NSStreamStatusNotOpen, @"Streams must not be opened.");
		CFReadStreamSetDispatchQueue((__bridge CFReadStreamRef)_inputStream, _workQueue);
		CFWriteStreamSetDispatchQueue((__bridge CFWriteStreamRef)_outputStream, _workQueue);
		
		_inputStream.delegate = self;
		_outputStream.delegate = self;
		
		[_inputStream open];
		[_outputStream open];
	});
}

- (void)closeRead
{
	dispatch_async(_workQueue, ^{
		if(_pendingReads.count == 0)
		{
			[_inputStream close];
			return;
		}
		
		_inputPendingClose = YES;
	});
}

- (void)closeWrite
{
	dispatch_async(_workQueue, ^{
		if(_pendingWrites.count == 0)
		{
			[_outputStream close];
			return;
		}
		
		_outputPendingClose = YES;
	});
}

- (void)_startReadingHeader
{
	if(_inputBytes == NULL)
	{
		_inputBytes = malloc(sizeof(uint64_t));
	}
	
	if(_inputStream.hasBytesAvailable == NO)
	{
		//No bytes are available. Wait for delegate to notify on bytes availability.
		return;
	}
	
	static uint64_t headerLength = sizeof(uint64_t);
	uint64_t bytesRemaining = headerLength - _inputCurrentBytesLength;
	_inputCurrentBytesLength += [_inputStream read:(_inputBytes + _inputCurrentBytesLength) maxLength:bytesRemaining];
	
	if(_inputCurrentBytesLength < headerLength)
	{
		return;
	}
	
	uint64_t header;
	memcpy(&header, _inputBytes, headerLength);
	//Convert to host byte order.
	NTOHLL(header);
	
	free(_inputBytes);
	_inputBytes = NULL;
	_inputCurrentBytesLength = 0;
	
	_inputTotalDataLength = header;
	_inputWaitingForHeader = NO;
	
	//Empty packet
	if(_inputTotalDataLength == 0)
	{
		return;
	}
	
	_inputWaitingForData = YES;
	
	[self _startReadingData];
}

- (void)_startReadingData
{
	if(_inputBytes == NULL)
	{
		_inputBytes = malloc(_inputTotalDataLength);
	}
	
	if(_inputStream.hasBytesAvailable == NO)
	{
		//No bytes are available. Wait for delegate to notify on bytes availability.
		return;
	}
	
	uint64_t bytesRemaining = _inputTotalDataLength - _inputCurrentBytesLength;
	_inputCurrentBytesLength += [_inputStream read:(_inputBytes + _inputCurrentBytesLength) maxLength:bytesRemaining];
	
	if(_inputCurrentBytesLength < _inputTotalDataLength)
	{
		return;
	}
	
	NSData* dataForUser = [NSData dataWithBytesNoCopy:_inputBytes length:_inputTotalDataLength freeWhenDone:YES];
	void (^pendingTask)(NSData *data, NSError *error) = _pendingReads.firstObject;
	
	pendingTask(dataForUser, nil);
	
	[_pendingReads removeObjectAtIndex:0];
	
	_inputBytes = NULL;
	_inputTotalDataLength = 0;
	_inputCurrentBytesLength = 0;
	_inputWaitingForData = NO;

	if(_pendingReads.count > 0)
	{
		_inputWaitingForHeader = YES;
		[self _startReadingHeader];
		
		return;
	}
	
	if(_inputPendingClose == YES)
	{
		[_inputStream close];
	}
}

- (void)_errorOutForReadRequest:(void (^)(NSData *data, NSError *error))request
{
	if(_inputStream.streamStatus == NSStreamStatusClosed)
	{
		request(nil, [NSError errorWithDomain:@"DTXSocketConnectionErrorDomain" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Reading is closed."}]);
		return;
	}
	
	if(_inputStream.streamStatus == NSStreamStatusError)
	{
		request(nil, _inputStream.streamError);
		return;
	}
}

- (void)_errorOutAllPendingReadRequests
{
	[_pendingReads enumerateObjectsUsingBlock:^(void (^ _Nonnull obj)(NSData *, NSError *), NSUInteger idx, BOOL * _Nonnull stop) {
		[self _errorOutForReadRequest:obj];
	}];
}

- (void)readDataWithCompletionHandler:(void (^)(NSData *data, NSError *error))completionHandler
{
	dispatch_async(_workQueue, ^{
		BOOL readsPending = _pendingReads.count > 0;
		
		if(_inputStream.streamStatus >= NSStreamStatusClosed)
		{
			[self _errorOutForReadRequest:completionHandler];
			return;
		}

		//TODO: Decide what the correct behavior is, if pending read close.
		
		//Queue the pending read request.
		[_pendingReads addObject:completionHandler];
		
		//If there were pending reads, the system should attempt to handle this request in the future.
		if(readsPending)
		{
			return;
		}
		
		//Start reading
		_inputWaitingForHeader = YES;
		
		if(_inputStream.streamStatus >= NSStreamStatusOpen)
		{
			[self _startReadingHeader];
		}
	});
}

- (void)_prepareHeaderDataForData:(NSData*)data
{
	uint64_t length = data.length;
	HTONLL(length);
	_outputData = [NSData dataWithBytes:&length length:sizeof(uint64_t)];
}

- (void)_startWritingHeader
{
	if(_outputStream.hasSpaceAvailable == NO)
	{
		//No space is available. Wait for delegate to notify on space availability.
		return;
	}
	
	static uint64_t headerLength = sizeof(uint64_t);
	uint64_t bytesRemaining = headerLength - _outputCurrentBytesLength;
	
	_outputCurrentBytesLength += [_outputStream write:(_outputData.bytes + _outputCurrentBytesLength) maxLength:bytesRemaining];
	
	if(_outputCurrentBytesLength < headerLength)
	{
		return;
	}
	
	_outputWaitingForHeader = NO;
	
	_outputData = _outputPendingDatasToBeWritten.firstObject;
	[_outputPendingDatasToBeWritten removeObjectAtIndex:0];
	
	_outputWaitingForData = YES;
	
	[self _startWritingData];
}

- (void)_startWritingData
{
	if(_outputStream.hasSpaceAvailable == NO)
	{
		//No space is available. Wait for delegate to notify on space availability.
		return;
	}
	
	uint64_t bytesRemaining = _outputData.length - _outputCurrentBytesLength;
	_outputCurrentBytesLength += [_outputStream write:(_outputData.bytes + _outputCurrentBytesLength) maxLength:bytesRemaining];
	
	if(_outputCurrentBytesLength < _outputData.length)
	{
		return;
	}
	
	void (^pendingTask)(NSError *error) = _pendingWrites.firstObject;
	
	pendingTask(nil);
	
	[_pendingWrites removeObjectAtIndex:0];
	
	_outputData = NULL;
	_outputCurrentBytesLength = 0;
	_outputWaitingForData = NO;
	
	if(_pendingWrites.count > 0)
	{
		_outputWaitingForHeader = YES;
		[self _prepareHeaderDataForData:_outputPendingDatasToBeWritten.firstObject];
		[self _startWritingHeader];
		
		return;
	}
	
	if(_outputPendingClose == YES)
	{
		[_outputStream close];
	}
}

- (void)_errorOutForWriteRequest:(void (^)(NSError* __nullable error))request
{
	if(_outputStream.streamStatus == NSStreamStatusClosed)
	{
		request([NSError errorWithDomain:@"DTXSocketConnectionErrorDomain" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Writing is closed."}]);
		return;
	}
	
	if(_outputStream.streamStatus == NSStreamStatusError)
	{
		request(_outputStream.streamError);
		return;
	}
}

- (void)_errorOutAllPendingWriteRequests
{
	[_pendingWrites enumerateObjectsUsingBlock:^(void (^ _Nonnull obj)(NSError *), NSUInteger idx, BOOL * _Nonnull stop) {
		[self _errorOutForWriteRequest:obj];
	}];
}

- (void)writeData:(NSData *)data withCompletionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	dispatch_async(_workQueue, ^{
		BOOL writesPending = _pendingWrites.count > 0;
		
		if(_outputStream.streamStatus >= NSStreamStatusClosed)
		{
			[self _errorOutForWriteRequest:completionHandler];
			return;
		}
		
		//TODO: Decide what the correct behavior is, if pending write close.
		
		//Queue the pending write request.
		[_pendingWrites addObject:completionHandler];
		[_outputPendingDatasToBeWritten addObject:data];
		
		//If there were pending writes, the system should attempt to handle this request in the future.
		if(writesPending)
		{
			return;
		}
		
		[self _prepareHeaderDataForData:data];
		
		//Start reading
		_outputWaitingForHeader = YES;
		
		if(_outputStream.streamStatus >= NSStreamStatusOpen)
		{
			[self _startWritingHeader];
		}
	});
}

#pragma mark NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
	if(aStream == _inputStream)
	{
		switch (eventCode) {
			case NSStreamEventOpenCompleted:
				if(_inputWaitingForHeader)
				{
					[self _startReadingHeader];
				}
				break;
			case NSStreamEventHasBytesAvailable:
				if(_inputWaitingForHeader)
				{
					[self _startReadingHeader];
				}
				else if(_inputWaitingForData)
				{
					[self _startReadingData];
				}
				break;
			case NSStreamEventErrorOccurred:
			case NSStreamEventEndEncountered:
				[self _errorOutAllPendingReadRequests];
				if([self.delegate respondsToSelector:@selector(readClosedForSocketConnection:)])
				{
					[self.delegate readClosedForSocketConnection:self];
				}
				break;
			default:
				break;
		}
	}
	else
	{
		switch (eventCode) {
			case NSStreamEventOpenCompleted:
				if(_outputWaitingForHeader)
				{
					[self _startWritingHeader];
				}
				break;
			case NSStreamEventHasBytesAvailable:
				if(_outputWaitingForHeader)
				{
					[self _startWritingHeader];
				}
				else if(_outputWaitingForData)
				{
					[self _startWritingData];
				}
				break;
			case NSStreamEventErrorOccurred:
			case NSStreamEventEndEncountered:
				[self _errorOutAllPendingWriteRequests];
				if([self.delegate respondsToSelector:@selector(writeClosedForSocketConnection:)])
				{
					[self.delegate writeClosedForSocketConnection:self];
				}
				break;
			default:
				break;
		}
	}
}

@end