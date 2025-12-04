--[=[
	RetryAsync Module: Automatic retry logic with exponential backoff
	
	Executes a function with automatic retry logic on failure, using exponential
	backoff between attempts. Supports custom error handlers for specialized retry
	logic beyond standard pcall behavior.
	
	Return type: (Function, MaxAttempts, PauseConstant?, PauseExponent?, CustomHandler?) -> (Success, ...Results)
	Example usage:
		local RetryAsync = require(script.Parent.RetryAsync)
		local Success, Result = RetryAsync(function()
			return DataStore:GetAsync(Key)
		end, 5, 1, 2)
--]=]

--!strict

type ExecutableFunction = (...any) -> ...any
export type Handler = (...any) -> (boolean, ...any)

local function RetryAsync(Func: ExecutableFunction, MaximumAttempts: number, PauseConstantValue: number?, PauseExponentValue: number?, CustomHandler: Handler?): (boolean, ...any)
	local PauseConstant: number = PauseConstantValue or 0
	local PauseExponent: number = PauseExponentValue or 0
	local ExecutionHandler: Handler = CustomHandler or pcall
	local CurrentAttempt = 0
	local Success: boolean
	local ResultData: {any}

	while CurrentAttempt < MaximumAttempts do
		CurrentAttempt += 1
		local ReturnedValues: {any} = {ExecutionHandler(Func)}
		Success = table.remove(ReturnedValues, 1) :: boolean
		ResultData = ReturnedValues

		if Success then
			break
		end

		local DelayDuration = PauseConstant + (PauseExponent ^ CurrentAttempt)
		if CurrentAttempt < MaximumAttempts then
			task.wait(DelayDuration)
		end
	end

	if Success then
		return Success, table.unpack(ResultData)
	else
		local Error = not Success and ResultData[1] :: any or nil
		return Success, Error :: any
	end
end

return RetryAsync