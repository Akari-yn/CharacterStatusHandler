--!strict

--[[
	StatusModule
	Handles the application, removal, and prioritization of status effects on characters,
	with support for stacking effects.

	Author: @akari_yn
	Date: 2025-07-13
	Version: 0.9.0

	---------------------------------------------------------------------------
	
	HOW IT WORKS:
	
	1. APPLYING A STATUS:
	   Call StatusModule.apply(character, statusName, statusInfo)
	   - `character`: The character model to affect.
	   - `statusName`: A unique string for the status (e.g., "Sprint", "Slowed").
	   - `statusInfo`: A table containing the status details:
	     - `Priority` (number): Higher numbers take precedence.
	     - `Duration` (number): How long the status lasts in seconds. Use `math.huge` for a permanent status.
	     - `Properties` (table): A dictionary of Humanoid properties to change.
	       Each property is a table with a `Value` and a `StackType`.
	       - `Value` (number): The value of the modification.
	       - `StackType` (string): How the value is applied. Can be:
	         - "Set": Overrides the base value and all lower-priority effects.
	         - "Add": Adds to the final value. (e.g., +10 speed).
	         - "Multiply": Multiplies the base value. (e.g., 1.5 for +50% speed).

	2. PRIORITY & STACKING:
	   - For each property (e.g., WalkSpeed), the module gathers all active effects.
	   - The effect with the highest `Priority` wins.
	   - If the highest priority effect is "Set", it becomes the final value. All lower-priority effects for that property are ignored.
	   - If the highest priority effects are "Add" or "Multiply", all "Add" and "Multiply" effects are combined. Any lower-priority "Set" effects are ignored.
	   - Calculation: Final = (Base * Multipliers) + Additions.
	   - Tie-Breaker: If priorities are equal, the first-applied status wins.

	---------------------------------------------------------------------------
	
	EXAMPLE USAGE:
	```lua
	local StatusModule = require(game.ServerScriptService.StatusModule)
	local character = script.Parent.Parent
	
	-- A sprint that ADDS 10 speed (Priority 10)
	local sprintStatus = {
		Priority = 10,
		Duration = 10,
		Properties = {
			WalkSpeed = { Value = 10, StackType = "Add" }
		}
	}
	StatusModule.apply(character, "Sprint", sprintStatus)

	-- A coffee buff that MULTIPLIES speed by 1.2x (Priority 10)
	-- This will stack with the sprint. Final speed = (16 * 1.2) + 10 = 29.2
	local coffeeBuff = {
		Priority = 10,
		Duration = 30,
		Properties = {
			WalkSpeed = { Value = 1.2, StackType = "Multiply" }
		}
	}
	StatusModule.apply(character, "CoffeeBuff", coffeeBuff)
	
	-- A "Slowed" debuff that SETS speed to 8 (Priority 20)
	-- This has higher priority, so it overrides the sprint and coffee. Final speed = 8
	local slowDebuff = {
		Priority = 20,
		Duration = 5,
		Properties = {
			WalkSpeed = { Value = 8, StackType = "Set" }
		}
	}
	StatusModule.apply(character, "Slowed", slowDebuff)
	```
]]

--[[
	TODO:
	1. Replicate default properties on character initialization.
	2. Refine warnings
]]

--// Services \\--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Types \\--

type stackType = "Set" | "Add" | "Multiply"
type validProperty = "WalkSpeed" | "JumpPower" | "JumpHeight" | "MaxHealth"

-- Type for a single property effect
type PropertyEffect = {
	Value: any,
	StackType: stackType,
}

-- Type for the status information passed to apply()
type StatusInfo = {
	Priority: number?,
	Duration: number?,
	Timestamp: number?, -- used for synchronization
	Properties: { [validProperty]: PropertyEffect }?,
	Callback: ((character: Model, removed: boolean) -> ())?, -- Optional callback when status is removed or expires
}

type ReadOnlyStatus = {
	read Priority: number,
	read Duration: number,
	read Timestamp: number,
	read Properties: { [validProperty]: PropertyEffect },
}

-- Internal type for active status tracking
type ActiveStatus = {
	Priority: number,
	Duration: number,
	Properties: { [validProperty]: PropertyEffect },
	Timestamp: number,
	Callback: ((character: Model, removed: boolean) -> ())?, -- Optional callback when status is removed or expires
}

-- Internal type for effect calculations
type EffectData = {
	Priority: number,
	Timestamp: number,
	StackType: stackType,
	Value: number,
}

type SyncData = {
	Character: Model,
	Timestamp: number,
} & ({
	Action: "apply",
	StatusName: string,
	StatusInfo: StatusInfo,
} | {
	Action: "remove",
	StatusName: string,
} | {
	Action: "clear",
})

type SyncRequestData = {
	AllStatuses: { [string]: ActiveStatus },
	DefaultProperties: { [validProperty]: any },
	Timestamp: number,
}

-- Main module type with proper function signatures
type StatusModule = {
	---
	-- Applies a status effect to a character.
	-- @param character The character model.
	-- @param statusName A unique string identifier for the status.
	-- @param statusInfo A table with Priority, Duration, and Properties.
	--
	apply: (character: Model, statusName: string, statusInfo: StatusInfo) -> (),

	---
	-- Manually removes a status effect from a character.
	-- @param character The character model.
	-- @param statusName The identifier of the status to remove.
	--
	remove: (character: Model, statusName: string, timestamp: number?) -> (),

	---
	-- Initializes a character's default properties.
	-- This should be called when a character is first added to the game.
	-- @param character The character model to initialize.
	-- @param defaultProperties A table of default properties for the character.
	--
	initCharacter: (character: Model, defaultProperties: { [validProperty]: any }?) -> (),

	---
	-- Removes all status effects from a character and cleans up.
	-- This should be called when a character is removed from the game.
	-- @param character The character model to clean up.
	--
	removeCharacter: (character: Model) -> (),

	---
	-- Checks if a character has a specific status effect.
	-- @param character The character model.
	-- @param statusName The identifier of the status to check.
	-- @return True if the status exists, false otherwise.
	--
	hasStatus: (character: Model, statusName: string) -> boolean,

	---
	-- Gets all active status effects for a character.
	-- @param character The character model.
	-- @return An array of status names.
	--
	getActiveStatuses: (character: Model) -> { string },

	---
	-- Gets detailed information about a specific status effect.
	-- @param character The character model.
	-- @param statusName The identifier of the status.
	-- @return StatusInfo table or nil if not found.
	--
	getStatusInfo: (character: Model, statusName: string) -> StatusInfo?,

	---
	-- Clears all status effects from a character without removing the character.
	-- @param character The character model.
	--
	clearAllStatuses: (character: Model, timestamp: number?) -> (),

	---
	-- Gets the remaining duration of a status effect.
	-- @param character The character model.
	-- @param statusName The identifier of the status.
	-- @return Remaining time in seconds, or nil if status not found.
	--
	getRemainingDuration: (character: Model, statusName: string) -> number?,

	---
	-- Extends or reduces the duration of an existing status effect.
	-- @param character The character model.
	-- @param statusName The identifier of the status.
	-- @param additionalTime Time to add (positive) or subtract (negative).
	--
	modifyDuration: (character: Model, statusName: string, additionalTime: number) -> (),

	---
	-- Advances the state of all active statuses.
	-- This function is called on each heartbeat to manage durations and cleanup.
	--
	advanceState: () -> (),
}

--// Constants \\--

local IS_SERVER = RunService:IsServer()

local ALLOWED_PROPERTIES: { [validProperty]: string } = {
	WalkSpeed = "number",
	JumpPower = "number",
	JumpHeight = "number",
	MaxHealth = "number",
}

-- Valid stack types
local VALID_STACK_TYPES: { [stackType]: boolean } = {
	Set = true,
	Add = true,
	Multiply = true,
}

local DEFAULT_DURATION = math.huge -- Default duration for statuses if not specified
local DEFAULT_STACK_TYPE: "Set" = "Set" -- Default stack type for properties
local DEFAULT_PRIORITY = 0 -- Default priority for statuses if not specified

local SYNC_REMOTE_NAME = "STATUS_HANDLER_StatusSync" -- Remote event name for syncing status changes
local SYNC_REQUEST_REMOTE_NAME = "STATUS_HANDLER_SyncRequest" -- Remote event name for sync requests
local STATUS_SYNC_REMOTE = if IS_SERVER
	then ReplicatedStorage:FindFirstChild(SYNC_REMOTE_NAME) :: RemoteEvent
	else ReplicatedStorage:WaitForChild(SYNC_REMOTE_NAME) :: RemoteEvent
local SYNC_REQUEST_REMOTE = if IS_SERVER
	then ReplicatedStorage:FindFirstChild(SYNC_REQUEST_REMOTE_NAME) :: RemoteFunction
	else ReplicatedStorage:WaitForChild(SYNC_REQUEST_REMOTE_NAME) :: RemoteFunction

local SYNC_ALL_CHARACTERS = false -- Whether to sync all characters to client

if not STATUS_SYNC_REMOTE then
	local newRemote = Instance.new("RemoteEvent", ReplicatedStorage)
	newRemote.Name = SYNC_REMOTE_NAME

	STATUS_SYNC_REMOTE = newRemote
end

if not SYNC_REQUEST_REMOTE then
	local newRemote = Instance.new("RemoteFunction", ReplicatedStorage)
	newRemote.Name = SYNC_REQUEST_REMOTE_NAME

	SYNC_REQUEST_REMOTE = newRemote
end

assert(STATUS_SYNC_REMOTE and STATUS_SYNC_REMOTE:IsA("RemoteEvent"), "STATUS_SYNC_REMOTE must be a RemoteEvent")
assert(SYNC_REQUEST_REMOTE and SYNC_REQUEST_REMOTE:IsA("RemoteFunction"), "SYNC_REQUEST_REMOTE must be a RemoteFunction")

--// Variables \\--

local activeStatuses: { [Model]: { [string]: ActiveStatus } } = {}
local defaultProperties: { [Model]: { [validProperty]: any } } = {}
local characterList: { [Model]: RBXScriptConnection } = {}

do
	local tempHumanoid: any = Instance.new("Humanoid")
	local function index(obj: any, key: string)
		return obj[key]
	end

	for propertyName, valueType in ALLOWED_PROPERTIES do
		local success, value = pcall(index, tempHumanoid, propertyName)
		if success then
			if type(value) ~= valueType then
				warn(`StatusModule: Property '{propertyName}' must be of type '{valueType}', but got '{type(value)}'.`)
			end
		else
			warn(`StatusModule: Invalid property '{propertyName}' for Humanoid. Error: {value}`)
		end
	end
	tempHumanoid:Destroy()
end

--// Module \\--

local StatusModule = {} :: StatusModule

--// Sync Functions \\--

-- For future bandwidth optimization, we can use these functions to serialize and deserialize sync data.
local function writeSyncData(syncData: SyncData): any
	return syncData
end

local function readSyncData(data: any): SyncData
	return data
end

local function writeSyncRequestData(syncRequestData: SyncRequestData | { [Model]: SyncRequestData }): any
	return syncRequestData
end

local function readSyncRequestData(data: any): { [Model]: SyncRequestData } | SyncRequestData
	return data
end

local function syncStatusChange(syncData: SyncData, targetPlayer: Player?)
	assert(IS_SERVER, "syncStatusChange can only be called from the server")

	if not syncData or not syncData.Character then
		warn("StatusModule: Cannot sync status change - invalid sync data provided.")
		return
	end

	if targetPlayer then
		STATUS_SYNC_REMOTE:FireClient(targetPlayer, writeSyncData(syncData))
	elseif SYNC_ALL_CHARACTERS then
		STATUS_SYNC_REMOTE:FireAllClients(writeSyncData(syncData))
	else
		local player = Players:GetPlayerFromCharacter(syncData.Character)
		if player then
			STATUS_SYNC_REMOTE:FireClient(player, writeSyncData(syncData))
		else
			warn(
				`StatusModule: Cannot sync status change for character '{syncData.Character.Name}' - no associated player found.`
			)
		end
	end
end

--// Private Functions \\--

---
-- The core logic function. Recalculates all properties for a character based on
-- all active statuses and their stacking rules.
-- @param character The character model to update.
--
local function updateCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		warn(`StatusModule: Cannot update character '{character.Name}' - no Humanoid found.`)
		return
	end
	if not defaultProperties[character] then
		warn(`StatusModule: Cannot update character '{character.Name}' - no default properties found. Call initCharacter first.`)
		return
	end

	local statuses = activeStatuses[character]

	-- If no statuses are active, revert to default properties.
	if not statuses or next(statuses) == nil then
		for property, value in defaultProperties[character] do
			(humanoid :: any)[property] = value
		end
		return
	end
	-- This table will hold the final calculated values for each property.
	-- Stacking is resolved by sorting effects by priority and timestamp; "Set" overrides all, otherwise "Add" and "Multiply" stack.
	local finalProperties: { [validProperty]: any } = {}

	-- Iterate through each property this module can control.
	for propName in ALLOWED_PROPERTIES do
		local baseValue = defaultProperties[character][propName]
		if baseValue == nil then continue end

		-- 1. Gather all active effects for the current property.
		local effectsForProp: { EffectData } = {}
		for statusName, status in statuses do
			if status.Properties[propName] then
				local effect = status.Properties[propName]
				if effect.Value == nil or not effect.StackType then
					warn(
						`StatusModule: Invalid effect data for property '{propName}' in status '{statusName}' on character '{character.Name}' - skipping.`
					)
					continue
				end
				table.insert(effectsForProp, {
					Priority = status.Priority,
					Timestamp = status.Timestamp,
					StackType = effect.StackType,
					Value = effect.Value,
				})
			end
		end

		-- If there are no effects for this property, it remains at its base value.
		if #effectsForProp == 0 then
			finalProperties[propName] = baseValue
			continue
		end

		-- 2. Sort the effects by priority (and timestamp as a tie-breaker).
		table.sort(effectsForProp, function(a: EffectData, b: EffectData)
			if a.Priority ~= b.Priority then
				return a.Priority > b.Priority
			else
				return a.Timestamp < b.Timestamp
			end
		end)

		-- 3. Determine the final value based on the highest priority effect's type.
		local dominantEffect = effectsForProp[1]

		if dominantEffect.StackType == "Set" then
			-- If the highest priority effect is "Set", it wins. No stacking needed.
			finalProperties[propName] = dominantEffect.Value
		else
			-- If the highest priority is "Add" or "Multiply", we stack all of them.
			-- Any lower-priority "Set" effects are ignored.
			local totalAddition = 0
			local totalMultiplier = 1

			for _, effect in effectsForProp do
				if effect.StackType == "Add" then
					totalAddition = totalAddition + effect.Value
				elseif effect.StackType == "Multiply" then
					totalMultiplier = totalMultiplier + (effect.Value - 1)
				elseif effect.StackType == "Set" then
					-- We explicitly ignore "Set" types here because we know the dominant
					-- effect is not "Set", so any "Set" found must be of lower priority.
				else
					warn(
						`StatusModule: Unknown StackType '{effect.StackType}' found while calculating '{propName}' for character '{character.Name}' - ignoring.`
					)
				end
			end

			finalProperties[propName] = (baseValue * totalMultiplier) + totalAddition
		end
	end
	-- 4. Apply all the calculated final properties to the humanoid.
	for propName, value in finalProperties do
		local success = pcall(function()
			(humanoid :: any)[propName] = value
		end)
		if not success then
			warn(`StatusModule: Failed to set property '{propName}' to {value} on character '{character.Name}'`)
		end
	end
end

---
-- Gets the current time in seconds since the epoch.
-- @return The current time in seconds.
local function getTime(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

--// Public Functions \\--

function StatusModule.apply(character: Model, statusName: string, statusInfo: StatusInfo)
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot apply status - invalid character model provided.")
		return
	end

	if not statusName then
		warn("StatusModule: Cannot apply status - statusName cannot be nil.")
		return
	end

	if not statusInfo then
		warn("StatusModule: Cannot apply status - statusInfo cannot be nil.")
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		warn(`StatusModule: Cannot apply status '{statusName}' to character '{character.Name}' - no Humanoid found.`)
		return
	end

	if not defaultProperties[character] then StatusModule.initCharacter(character) end
	if not activeStatuses[character] then activeStatuses[character] = {} end

	local duration = statusInfo.Duration
	if duration and duration < 0 then
		warn(`StatusModule: Cannot apply status '{statusName}' to character '{character.Name}' - Duration cannot be negative.`)
		return
	end

	-- Sanitize and validate the properties being applied.
	local sanitizedProperties: { [validProperty]: PropertyEffect } = {}
	if statusInfo.Properties then
		for propName, propInfo in statusInfo.Properties do
			local propertyType = ALLOWED_PROPERTIES[propName]
			if not propertyType then
				warn(
					`StatusModule: Invalid property '{propName}' in statusInfo.Properties for status '{statusName}' on character '{character.Name}' - ignoring.`
				)
				continue
			end

			if type(propInfo) ~= "table" then
				warn(
					`StatusModule: Property '{propName}' in statusInfo.Properties for status '{statusName}' on character '{character.Name}' must be a table - ignoring.`
				)
				continue
			end

			local value = propInfo.Value
			if type(value) ~= propertyType then
				warn(
					`StatusModule: Property '{propName}' value in status '{statusName}' on character '{character.Name}' must be a {propertyType}, got {type(
						value
					)} - ignoring.`
				)
				continue
			end

			local stackType: stackType = propInfo.StackType or DEFAULT_STACK_TYPE
			local validStackType = VALID_STACK_TYPES[stackType]

			if not validStackType then
				warn(
					`StatusModule: Invalid StackType '{stackType}' for property '{propName}' in status '{statusName}' on character '{character.Name}' - ignoring.`
				)
				continue
			end

			sanitizedProperties[propName] = {
				Value = value,
				StackType = stackType :: stackType,
			}
		end
	else
		warn(
			`StatusModule: No properties specified for status '{statusName}' on character '{character.Name}' - status will have no effect.`
		)
	end

	local callback = statusInfo.Callback
	if callback and type(callback) ~= "function" then
		warn(`StatusModule: Callback for status '{statusName}' on character '{character.Name}' must be a function - ignoring.`)
		callback = nil
	end

	local existingStatus: ActiveStatus? = activeStatuses[character][statusName]
	local timestamp = statusInfo.Timestamp or getTime()

	if existingStatus then
		if existingStatus.Timestamp and existingStatus.Timestamp > timestamp then
			warn(
				`StatusModule: Attempted to apply older status '{statusName}' to character '{character.Name}' - ignoring (existing: {existingStatus.Timestamp}, new: {timestamp}).`
			)
			return
		end

		-- Refresh existing status
		existingStatus.Timestamp = timestamp
		existingStatus.Duration = duration or existingStatus.Duration
		existingStatus.Properties = sanitizedProperties
		existingStatus.Priority = statusInfo.Priority or existingStatus.Priority
	else
		-- Add new status
		activeStatuses[character][statusName] = {
			Priority = statusInfo.Priority or DEFAULT_PRIORITY,
			Duration = duration or DEFAULT_DURATION,
			Properties = sanitizedProperties,
			Timestamp = timestamp,
			Callback = callback,
		}
	end

	updateCharacter(character)
	if not IS_SERVER then return end

	syncStatusChange({
		Character = character,
		Timestamp = timestamp,
		Action = "apply" :: "apply",
		StatusName = statusName,
		StatusInfo = statusInfo,
	})
end

function StatusModule.remove(character: Model, statusName: string, timestamp: number?)
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot remove status - invalid character model provided.")
		return
	end

	if not statusName then
		warn("StatusModule: Cannot remove status - statusName cannot be nil.")
		return
	end

	if not activeStatuses[character] then
		warn(`StatusModule: Cannot remove status '{statusName}' - character '{character.Name}' has no active statuses.`)
		return
	end

	local statuses = activeStatuses[character]
	local existingStatus = statuses[statusName]

	if not existingStatus then
		warn(`StatusModule: Status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	if timestamp and existingStatus.Timestamp > timestamp then
		warn(
			`StatusModule: Attempted to remove older status '{statusName}' from character '{character.Name}' - ignoring (existing: {existingStatus.Timestamp}, remove: {timestamp}).`
		)
		return
	end

	local callback = existingStatus.Callback
	if callback then
		-- Call the callback function with the character and removed status flag
		task.spawn(pcall, callback, character, true)
	end

	statuses[statusName] = nil
	updateCharacter(character)

	if not IS_SERVER then return end

	syncStatusChange({
		Character = character,
		Action = "remove" :: "remove",
		StatusName = statusName,
		Timestamp = getTime(),
	})
end

function StatusModule.hasStatus(character: Model, statusName: string): boolean
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot check status - invalid character model provided.")
		return false
	end

	if not statusName then
		warn("StatusModule: Cannot check status - statusName cannot be nil.")
		return false
	end

	if not activeStatuses[character] then return false end

	local statuses = activeStatuses[character]
	return statuses[statusName] ~= nil
end

function StatusModule.getActiveStatuses(character: Model): { string }
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot get active statuses - invalid character model provided.")
		return {}
	end

	if not activeStatuses[character] then return {} end

	local statusNames: { string } = {}
	local statuses = activeStatuses[character]

	for statusName in statuses do
		table.insert(statusNames, statusName)
	end

	return statusNames
end

function StatusModule.getStatusInfo(character: Model, statusName: string): ReadOnlyStatus?
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot get status info - invalid character model provided.")
		return nil
	end

	if not statusName then
		warn("StatusModule: Cannot get status info - statusName cannot be nil.")
		return nil
	end

	if not activeStatuses[character] then return nil end

	local statuses = activeStatuses[character]
	local existingStatus = statuses[statusName]
	if not existingStatus then return nil end

	return table.freeze({
		Priority = existingStatus.Priority,
		Duration = existingStatus.Duration,
		Properties = table.freeze(table.clone(existingStatus.Properties)),
		Timestamp = existingStatus.Timestamp,
	})
end

function StatusModule.clearAllStatuses(character: Model, timestamp: number?)
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot clear statuses - invalid character model provided.")
		return
	end

	if not activeStatuses[character] then
		warn(`StatusModule: Cannot clear statuses - character '{character.Name}' has no active statuses.`)
		return
	end

	if timestamp then
		local updated = false
		for statusName, status in activeStatuses[character] do
			if status.Timestamp > timestamp then continue end
			activeStatuses[character][statusName] = nil
			updated = true
		end

		if not updated then
			warn(
				`StatusModule: No statuses cleared for character '{character.Name}' - all existing statuses are newer than timestamp {timestamp}.`
			)
			return
		end
	else
		table.clear(activeStatuses[character])
	end

	updateCharacter(character)

	if not IS_SERVER then return end

	syncStatusChange({
		Character = character,
		Action = "clear" :: "clear",
		Timestamp = getTime(),
	})
end

function StatusModule.getRemainingDuration(character: Model, statusName: string): number?
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot get remaining duration - invalid character model provided.")
		return nil
	end

	if not statusName then
		warn("StatusModule: Cannot get remaining duration - statusName cannot be nil.")
		return nil
	end

	if not activeStatuses[character] then return nil end

	local statuses = activeStatuses[character]
	local statusInfo = statuses[statusName]
	if not statusInfo then return nil end

	if statusInfo.Duration == math.huge then return math.huge end

	local currentTime = getTime()
	local elapsed = currentTime - statusInfo.Timestamp
	local remaining = statusInfo.Duration - elapsed

	-- Ensure we don't return negative durations
	return math.max(0, remaining)
end

function StatusModule.modifyDuration(character: Model, statusName: string, additionalTime: number)
	if not character or not character:IsA("Model") then
		warn("StatusModule: Cannot modify duration - invalid character model provided.")
		return
	end

	if not statusName then
		warn("StatusModule: Cannot modify duration - statusName cannot be nil.")
		return
	end

	if type(additionalTime) ~= "number" then
		warn("StatusModule: Cannot modify duration - additionalTime must be a number.")
		return
	end

	if not activeStatuses[character] then return end

	local statuses = activeStatuses[character]
	local statusInfo = statuses[statusName]

	if not statusInfo then
		warn(`StatusModule: Status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	if statusInfo.Duration == math.huge then
		warn(`StatusModule: Cannot modify duration for permanent status '{statusName}' on character '{character.Name}'.`)
		return
	end

	statusInfo.Duration = math.max(0, statusInfo.Duration + additionalTime)

	if statusInfo.Duration == 0 then
		warn(
			`StatusModule: Duration modification resulted in 0 duration for status '{statusName}' on character '{character.Name}' - status will expire immediately.`
		)
	end

	if not IS_SERVER then return end

	syncStatusChange({
		Character = character,
		Action = "apply" :: "apply",
		StatusName = statusName,
		StatusInfo = {
			Priority = statusInfo.Priority,
			Duration = statusInfo.Duration,
			Properties = statusInfo.Properties,
		} :: StatusInfo,
		Timestamp = getTime(),
	})
end

function StatusModule.initCharacter(character: Model, default: { [validProperty]: any }?)
	if not character or not character:IsA("Model") then
		warn("StatusModule: initCharacter requires a valid Model.")
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		warn("StatusModule: Cannot initialize character without a Humanoid.")
		return
	end

	if characterList[character] then
		if default then
			defaultProperties[character] = default
		end
		-- If already initialized, no need to reinitialize
		return
	end

	if default then
		-- If default properties are provided, use them
		defaultProperties[character] = default
	else
		-- Otherwise, initialize with current Humanoid properties
		defaultProperties[character] = {}
		for propertyName in ALLOWED_PROPERTIES do
			local success, value = pcall(function()
				return (humanoid :: any)[propertyName]
			end)
			if success then
				defaultProperties[character][propertyName] = value
			else
				warn(`StatusModule: Failed to read property '{propertyName}' from character '{character.Name}' Humanoid.`)
			end
		end
	end

	activeStatuses[character] = {}

	characterList[character] = character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(game) then StatusModule.removeCharacter(character) end
	end)

	if IS_SERVER then
		-- Log successful initialization
		local statusCount = 0
		if activeStatuses[character] then
			for _ in activeStatuses[character] do
				statusCount = statusCount + 1
			end
		end
		if statusCount == 0 then
			print(`StatusModule: Successfully initialized character '{character.Name}' with default properties.`)
		else
			print(`StatusModule: Successfully initialized character '{character.Name}' with {statusCount} active statuses.`)
		end
	end
end

function StatusModule.removeCharacter(character: Model)
	if not character or not character:IsA("Model") then
		warn("StatusModule: removeCharacter requires a valid Model.")
		return
	end

	if not characterList[character] then return end

	if character.Parent then
		-- Reset all properties to their defaults
		local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if humanoid and defaultProperties[character] then
			for propertyName, value in defaultProperties[character] do
				local success = pcall(function()
					(humanoid :: any)[propertyName] = value
				end)
				if not success then
					warn(
						`StatusModule: Failed to reset property '{propertyName}' to default value on character '{character.Name}' during cleanup.`
					)
				end
			end
		else
			if not humanoid then
				warn(`StatusModule: No Humanoid found for character '{character.Name}' during cleanup - cannot reset properties.`)
			end
		end
	end

	-- Clear all active statuses for this character
	activeStatuses[character] = nil
	defaultProperties[character] = nil

	-- Disconnect the AncestryChanged event if it exists
	if characterList[character] then
		characterList[character]:Disconnect()
		characterList[character] = nil
	end
end

function StatusModule.advanceState()
	local currentTime = getTime()
	local expiredCount = 0

	for character, statuses in activeStatuses do
		local needsUpdate = false
		for statusName, status in statuses do
			if currentTime - status.Timestamp < status.Duration then continue end

			local callback = status.Callback
			if callback then
				-- Call the callback function with the character and removed status flag
				task.spawn(pcall, callback, character, false)
			end

			-- Remove expired status
			statuses[statusName] = nil
			needsUpdate = true
			expiredCount = expiredCount + 1

			if IS_SERVER then
				syncStatusChange({
					Character = character,
					Action = "remove" :: "remove",
					StatusName = statusName,
					Timestamp = currentTime,
				})
			end
		end

		if needsUpdate then updateCharacter(character) end
	end

	-- Optional: Log expired statuses periodically (only on server to reduce spam)
	if IS_SERVER and expiredCount > 0 then print(`StatusModule: Expired {expiredCount} status effects in this heartbeat.`) end
end

--// Connections \\--

---
-- Heartbeat function to manage durations
--
RunService.Heartbeat:Connect(StatusModule.advanceState)

---
-- Handle remote requests for status sync
--
if IS_SERVER then
	SYNC_REQUEST_REMOTE.OnServerInvoke = function(player: Player): (SyncRequestData | { [Model]: SyncRequestData })?
		if not player or not player:IsA("Player") then
			warn("StatusModule: Invalid player requested sync data.")
			return nil
		end

		if SYNC_ALL_CHARACTERS then
			local syncData: { [Model]: SyncRequestData } = {}

			for character, statuses in activeStatuses do
				if not character:IsA("Model") then
					warn(`StatusModule: Invalid character model found in activeStatuses during sync - skipping.`)
					continue
				end

				local allStatuses = statuses or {}
				local defaultProps = defaultProperties[character] or {}

				if not defaultProps or next(defaultProps) == nil then
					warn(`StatusModule: No default properties found for character '{character.Name}' during sync.`)
				end

				syncData[character] = {
					AllStatuses = allStatuses,
					DefaultProperties = defaultProps,
					Timestamp = getTime(),
				}
			end

			return writeSyncRequestData(syncData)
		else
			local character = player.Character
			if not character or not character:IsA("Model") then
				warn(`StatusModule: Player '{player.Name}' requested sync but has no valid character.`)
				return nil
			end

			if not characterList[character] then StatusModule.initCharacter(character) end

			-- return all information client needed to sync
			local allStatuses = activeStatuses[character] or {}
			local defaultProps = defaultProperties[character] or {}

			if not defaultProps or next(defaultProps) == nil then
				warn(`StatusModule: No default properties found for character '{character.Name}' during sync request.`)
			end

			return writeSyncRequestData({
				AllStatuses = allStatuses,
				DefaultProperties = defaultProps,
				Timestamp = getTime(),
			})
		end
	end
else
	STATUS_SYNC_REMOTE.OnClientEvent:Connect(function(syncData: SyncData)
		syncData = readSyncData(syncData)

		if type(syncData) ~= "table" then
			warn("StatusModule: Received invalid sync data from server - expected table.")
			return
		end

		local character = syncData.Character
		local action = syncData.Action
		local timestamp = syncData.Timestamp

		if not character or not action or not character:IsA("Model") then
			warn(
				"StatusModule: Received incomplete sync data from server - missing character, action, or invalid character type."
			)
			return
		end

		if not timestamp then
			warn(
				`StatusModule: Received sync data without timestamp for action '{action}' on character '{character.Name}' - using current time.`
			)
			timestamp = getTime()
		end

		if syncData.Action == "apply" then
			local statusName = syncData.StatusName
			local statusInfo = syncData.StatusInfo

			if not statusName then
				warn(`StatusModule: Received apply action without valid statusName for character '{character.Name}'.`)
				return
			end

			if not statusInfo then
				warn(
					`StatusModule: Received apply action without statusInfo for status '{statusName}' on character '{character.Name}'.`
				)
				return
			end

			statusInfo.Timestamp = timestamp

			StatusModule.apply(character, statusName, statusInfo)
		elseif syncData.Action == "remove" then
			local statusName = syncData.StatusName

			if not statusName then
				warn(`StatusModule: Received remove action without valid statusName for character '{character.Name}'.`)
				return
			end

			if not StatusModule.hasStatus(character, statusName) then return end

			StatusModule.remove(character, statusName, timestamp)
		elseif syncData.Action == "clear" then
			StatusModule.clearAllStatuses(character, timestamp)
		else
			warn(`StatusModule: Unknown action '{action}' received from server for character '{character.Name}'.`)
		end
	end)

	local function initializeCharacter(character: Model, syncData: SyncRequestData)
		if not character or not character:IsA("Model") then
			warn("StatusModule: Cannot initialize character - invalid character model provided.")
			return
		end

		if not syncData then
			warn(`StatusModule: Cannot initialize character '{character.Name}' - no sync data provided.`)
			return
		end

		if not syncData.DefaultProperties then
			warn(`StatusModule: No default properties provided for character '{character.Name}' during initialization.`)
		end

		StatusModule.initCharacter(character, syncData.DefaultProperties)

		for statusName, status in syncData.AllStatuses do
			if not status.Properties or not status.Priority or not status.Duration or not status.Timestamp then
				warn(
					`StatusModule: Incomplete status data for '{statusName}' on character '{character.Name}' during initialization - skipping.`
				)
				continue
			end

			StatusModule.apply(character, statusName, {
				Priority = status.Priority,
				Duration = status.Duration,
				Properties = status.Properties,
				Timestamp = status.Timestamp,
			})
		end

		-- Update the character with the initial properties
		updateCharacter(character)
	end

	if SYNC_ALL_CHARACTERS then
		-- Sync all characters on client initialization
		local initialSyncData = SYNC_REQUEST_REMOTE:InvokeServer()
		if initialSyncData then
			initialSyncData = readSyncRequestData(initialSyncData) :: { [Model]: SyncRequestData }
			for character, syncData in initialSyncData do
				initializeCharacter(character, syncData)
			end
		else
			warn("StatusModule: Failed to retrieve initial sync data from server.")
		end
	else
		local character = Players.LocalPlayer.Character
		if character then -- only initialize if the character exists
			local initialSyncData: SyncRequestData = SYNC_REQUEST_REMOTE:InvokeServer()
			if initialSyncData then
				initialSyncData = readSyncRequestData(initialSyncData) :: SyncRequestData
				initializeCharacter(character, initialSyncData)
			else
				warn("StatusModule: Failed to retrieve initial sync data from server.")
			end
		end
	end
end

--// Return \\--

return StatusModule
