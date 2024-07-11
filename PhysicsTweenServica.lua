--[[
DestroyerCam, July 7th 2024
Tweens objects with custom physics.
]]

local PhysicsTweenService = {}

local PhysicsTween = {}
PhysicsTween.__index = PhysicsTween

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Lerps = require(script.Lerps)

export type PhysicsTween = {
	Instance: BasePart | Model,
	TweenInfo: TweenInfo,
	PlaybackState: Enum.PlaybackState,
	Completed: RBXScriptSignal,

	_COMPLETED_EVENT: BindableEvent,
	_id: number,
	_alpha: number,
	_repeatCount: number,
	_delayTimeElapsed: number,
	_isBinded: boolean,
	_isReversing: boolean,
	_connections: { RBXScriptConnection },

	_initialProperties: { [string]: any },
	_propertyTable: { [string]: any },

	_unbind: (self: PhysicsTween) -> (),
	_stepped: (self: PhysicsTween) -> (),
	Play: (self: PhysicsTween) -> (),
}

local function _mirrorPart(part: BasePart, pivot: CFrame): BasePart
	local mirrorPart = Instance.new("Part")

	local magnitude = (part.Position - pivot.Position).Magnitude
	local unit = (part.Position - pivot.Position).Unit
	local position = pivot.Position + magnitude * -unit

	mirrorPart.CanCollide = false
	mirrorPart.CanTouch = false
	mirrorPart.CanQuery = false
	mirrorPart.Anchored = false
	mirrorPart.Archivable = false
	mirrorPart.Locked = true
	mirrorPart.Transparency = 1
	mirrorPart.Size = part.Size
	mirrorPart.CFrame = CFrame.new(position, position - part.CFrame.LookVector)
	mirrorPart.Massless = part.Massless

	--Makes sure the mass and densities of both parts match. Especially for mesh parts
	mirrorPart.CustomPhysicalProperties = part.CurrentPhysicalProperties
	mirrorPart.CustomPhysicalProperties = PhysicalProperties.new(
		part.CurrentPhysicalProperties.Density / (mirrorPart.Mass / part.Mass),
		part.CurrentPhysicalProperties.Friction,
		part.CurrentPhysicalProperties.Elasticity,
		part.CurrentPhysicalProperties.FrictionWeight,
		part.CurrentPhysicalProperties.ElasticityWeight
	)

	mirrorPart.Name = "CounterWeight"

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = mirrorPart
	weld.Part1 = part
	weld.Parent = mirrorPart

	return mirrorPart
end

local function _getCFrameOrientation(cframe: CFrame): Vector3
	local rx, ry, rz = cframe:ToOrientation()
	return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end

function PhysicsTweenService:Create(
	instance: Instance,
	tweenInfo: TweenInfo,
	propertyTable: { [string]: any }
): PhysicsTween
	assert(instance ~= nil, "PhysicsTweenService:Create failed because instance is null")
	assert(tweenInfo ~= nil, "Argument 2 missing or nil")
	assert(propertyTable ~= nil, "Argument 3 missing or nil")

	local tween = {}

	tween.Instance = instance
	tween.TweenInfo = tweenInfo
	tween.PlaybackState = Enum.PlaybackState.Begin

	tween._COMPLETED_EVENT = Instance.new("BindableEvent")
	tween.Completed = tween._COMPLETED_EVENT.Event

	tween._id = HttpService:GenerateGUID()
	tween._alpha = 0
	tween._repeatCount = 0
	tween._delayTimeElapsed = 0
	tween._isBinded = false
	tween._isReversing = false
	tween._connections = {}

	tween._initialProperties = {}
	tween._propertyTable = table.clone(propertyTable) --clone the table so any modifications made inside the tween won't affect scripts on the outside

	return setmetatable(tween :: any, PhysicsTween)
end

function PhysicsTween._unbind(self: PhysicsTween): ()
	if not self._isBinded then
		return
	end

	local tag = "tween_" .. self._id

	for _, connection in self._connections do
		connection:Disconnect()
	end

	if RunService:IsClient() then
		RunService:UnbindFromRenderStep(tag)
	end

	if self._propertyTable.CFrame ~= nil and not self.Instance:IsA("Model") then
		self.Instance.AssemblyLinearVelocity = Vector3.zero
		self.Instance.AssemblyAngularVelocity = Vector3.zero
	end

	if workspace:FindFirstChild(tag) then
		workspace[tag]:Destroy()
	end

	self._isBinded = false
end

function PhysicsTween._stepped(self: PhysicsTween, deltaTime: number): ()
	--Delays the tween if the delay time has not elapsed yet
	if self.TweenInfo.DelayTime > 0 and self._delayTimeElapsed < self.TweenInfo.DelayTime then
		self.PlaybackState = Enum.PlaybackState.Delayed
		self._delayTimeElapsed += deltaTime

		return
	end

	self.PlaybackState = Enum.PlaybackState.Playing

	self._alpha += (deltaTime / self.TweenInfo.Time) * (self._isReversing and -1 or 1)
	self._alpha = math.clamp(self._alpha, 0, 1)

	local alphaPrime = TweenService:GetValue(self._alpha, self.TweenInfo.EasingStyle, self.TweenInfo.EasingDirection)

	--Applies the properties of the tween. Also applies phsyics if the property is a CFrame
	for prop, goal in self._propertyTable do
		if prop == "CFrame" then
			local newCFrame: CFrame = self._initialProperties.CFrame:Lerp(self._propertyTable.CFrame, alphaPrime)

			local velocity = (newCFrame.Position - self.Instance:GetPivot().Position) * (1 / deltaTime)
			local angularVelocity = Vector3.new((self.Instance:GetPivot():ToObjectSpace(newCFrame)):ToEulerAngles())
				* (1 / deltaTime)

			if self.Instance:IsA("Model") then
				for _, part in self.Instance:GetDescendants() do
					if not part:IsA("BasePart") then
						continue
					end

					part.AssemblyLinearVelocity = velocity
					part.AssemblyAngularVelocity = angularVelocity
				end

				self.Instance:PivotTo(newCFrame)
			else
				self.Instance.AssemblyLinearVelocity = velocity
				self.Instance.AssemblyAngularVelocity = angularVelocity

				self.Instance.CFrame = newCFrame
			end
		else
			self.Instance[prop] =
				Lerps[typeof(goal)](self._initialProperties[prop], self._propertyTable[prop])(alphaPrime)
		end
	end

	--Completes, repeats, or reverses the tween once it runs out of time
	if self._alpha >= 1 or (self._isReversing and self._alpha <= 0) then
		if self.TweenInfo.Reverses and not self._isReversing then
			self._isReversing = true

			return
		elseif self._isReversing then
			self._isReversing = false
		end

		if self._repeatCount >= self.TweenInfo.RepeatCount and self.TweenInfo.RepeatCount ~= -1 then
			self:_unbind()
			self.PlaybackState = Enum.PlaybackState.Completed
			self._COMPLETED_EVENT:Fire(self.PlaybackState)
		end

		self._repeatCount += 1
		self._alpha = 0
		self._delayTimeElapsed = 0
	end
end

function PhysicsTween.Play(self: PhysicsTween): ()
	--Converts position and orientation properties into a cframe so physics can be applied to the instance without any extra steps
	if (self._propertyTable.Position or self._propertyTable.Orientation) and not self._propertyTable.CFrame then
		local position = self._propertyTable.Position or self.Instance:GetPivot().Position
		local orientation = self._propertyTable.Orientation or _getCFrameOrientation(self.Instance:GetPivot())

		self._propertyTable.CFrame = CFrame.new(position)
			* CFrame.fromOrientation(math.rad(orientation.X), math.rad(orientation.Y), math.rad(orientation.Z))
	end

	self._propertyTable.Position = nil
	self._propertyTable.Orientation = nil

	--Caches the initial properties of the instance
	if not next(self._initialProperties) then
		for prop in self._propertyTable do
			if prop == "CFrame" then
				self._initialProperties.CFrame = self.Instance:GetPivot()
			else
				self._initialProperties[prop] = self.Instance[prop]
			end
		end
	end

	--Unbinds the last tween
	if self._isBinded then
		self:_unbind()
	end

	--If the instance is a model, creates mirrored parts around the model's pivot.
	--It's a little hacky, but this lets us manipulate the part's AssemblyCenterOfMass so we can make it work with it's AssemblyAngularVelocity
	if self.Instance:IsA("Model") then
		local pivot = self.Instance:GetPivot()
		local tweenFolder = Instance.new("Folder")
		tweenFolder.Archivable = false
		tweenFolder.Name = "tween_" .. self._id

		for _, part in self.Instance:GetDescendants() do
			if not part:IsA("BasePart") then
				continue
			end
			if (part.Position - pivot.Position).Magnitude <= 0.05 then
				continue
			end

			_mirrorPart(part, pivot).Parent = tweenFolder
		end

		tweenFolder.Parent = workspace
	end

	--Starts the tween
	table.insert(
		self._connections,
		self.Instance.Destroying:Connect(function()
			self:_unbind()
		end)
	)

	if RunService:IsServer() then
		table.insert(self._connectionsRunService.PreSimulation:Connect(function(...)
			self:_stepped(...)
		end))
	else
		RunService:BindToRenderStep("tween_" .. self._id, 99, function(...)
			self:_stepped(...)
		end)
	end

	self._isBinded = true
end

function PhysicsTween.Cancel(self: PhysicsTween): ()
	self:_unbind()

	self._alpha = 0
	self._repeatCount = 0
	self._isReversing = false

	table.clear(self._initialProperties)

	self.PlaybackState = Enum.PlaybackState.Cancelled
end

function PhysicsTween.Pause(self: PhysicsTween): ()
	self:_unbind()
	self.PlaybackState = Enum.PlaybackState.Paused
end

return PhysicsTweenService
