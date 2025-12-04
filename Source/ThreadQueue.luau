--[=[
	ThreadQueue: Manage asynchronous task execution with ordering guarantees
	
	Requests to the same queue are processed in order. This avoids race conditions
	where a retry for an older request could complete after a newer request.
	
	ThreadQueue:SubmitAsync yields until the task has completed.
	
	Return type: ThreadQueue module
	
	Example usage:
		local Queue = ThreadQueue.New()
		local Success, Result = Queue:SubmitAsync(function()
			return "Task completed"
		end)
--]=]

--!strict

type QueueEntry = {
	Thread: thread,
	Callback: () -> any,
}

export type ThreadQueue = {
	Queue: { QueueEntry },
	Running: boolean,
	SubmitAsync: (self: ThreadQueue, Callback: () -> any) -> (boolean, any),
	GetLength: (self: ThreadQueue) -> number,
	SkipToLastEnqueued: (self: ThreadQueue) -> (),
}

local ThreadQueue = {}
ThreadQueue.__index = ThreadQueue

function ThreadQueue.New(): ThreadQueue
	local self = {
		Queue = {},
		Running = false,
	}

	setmetatable(self, ThreadQueue)

	return (self :: any) :: ThreadQueue
end

function ThreadQueue:SubmitAsync(Callback: () -> any): (boolean, any)
	local Entry: QueueEntry = {
		Thread = coroutine.running(),
		Callback = Callback,
	}

	table.insert(self.Queue, Entry)
	self:StartQueue()

	return coroutine.yield()
end

function ThreadQueue:GetLength(): number
		local Length = 0
		for Index, Value in self.Queue do
			Length += 1
		end

		return Length
	end

function ThreadQueue:SkipToLastEnqueued()
	local QueueRef: { QueueEntry } = self.Queue

	if self:GetLength() > 1 then
		local Last = QueueRef[#QueueRef]
		self.Queue = { Last }
	end
end

function ThreadQueue:StartQueue()
	if self.Running then
		return
	end

	self.Running = true

	task.defer(function()
		while self:GetLength() > 0 do
			self:PopQueue()
		end
		
		self.Running = false
	end)
end

function ThreadQueue:PopQueue()
	local Entry = table.remove(self.Queue, 1)
	if not Entry then
		return
	end

	local Success, Result = pcall(Entry.Callback)
	task.spawn(Entry.Thread, Success, Result)
end

return ThreadQueue