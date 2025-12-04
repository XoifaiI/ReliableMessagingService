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

type ThreadQueueData = {
	Queue: { QueueEntry },
	Running: boolean,
}

local ThreadQueue = {}
ThreadQueue.__index = ThreadQueue

export type ThreadQueue = typeof(setmetatable({} :: ThreadQueueData, ThreadQueue))

function ThreadQueue.New(): ThreadQueue
	local self: ThreadQueueData = {
		Queue = {},
		Running = false,
	}

	setmetatable(self, ThreadQueue)

	return self :: ThreadQueue
end

function ThreadQueue.SubmitAsync(self: ThreadQueue, Callback: () -> any): (boolean, any)
	local Entry: QueueEntry = {
		Thread = coroutine.running(),
		Callback = Callback,
	}

	table.insert(self.Queue, Entry)
	self:StartQueue()

	return coroutine.yield()
end

function ThreadQueue.GetLength(self: ThreadQueue): number
	return #self.Queue
end

function ThreadQueue.SkipToLastEnqueued(self: ThreadQueue): ()
	local QueueRef = self.Queue
	local Length = #QueueRef

	if Length > 1 then
		local Last = QueueRef[Length]
		table.clear(QueueRef)
		QueueRef[1] = Last
	end
end

function ThreadQueue.StartQueue(self: ThreadQueue): ()
	if self.Running then
		return
	end

	self.Running = true

	task.defer(function()
		while #self.Queue > 0 do
			self:PopQueue()
		end

		self.Running = false
	end)
end

function ThreadQueue.PopQueue(self: ThreadQueue): ()
	local Entry = table.remove(self.Queue, 1)
	if not Entry then
		return
	end

	local Success, Result = pcall(Entry.Callback)
	task.spawn(Entry.Thread, Success, Result)
end

return ThreadQueue