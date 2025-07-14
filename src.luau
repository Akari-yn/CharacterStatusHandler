--!strict

--[[
	StatusModule
	Handles the application, removal, and prioritization of status effects on characters,
	with support for stacking effects.

    Author: @akari_yn
    Date: 2025-07-13
    Version: 0.2.0

	---------------------------------------------------------------------------
	
	HOW IT WORKS:
	
	1. APPLYING A STATUS:
	   Call StatusModule.apply(character, statusName, statusInfo)
	   - `character`: The character model to affect.
	   - `statusName`: A unique string for the status (e.g., "Sprint", "Slowed").
	   - `statusInfo`: A table containing the status details:
	     - `Priority` (number): Higher numbers take precedence.
	     - `Duration` (number): How long the status lasts in seconds. Use `math.huge` for a permanent status.
	     - `Properties` (table): A dictionary of properties to change.
	       Each property is a table with a `Value` and a `StackType`.
	       - `Value` (any): The value of the modification.
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
		Tags = {"buff", "movement"},
		Properties = {
			WalkSpeed = { Value = 10, StackType = "Add" }
		}
	}
	StatusModule.apply(character, "Sprint", sprintStatus)

	-- Get statuses by tag
	local movementBuffs = StatusModule.getStatusesByTag(character, "movement")
	```
]]

-- Callback order:
-- 1. Insert
-- 2. Update
-- 3. OnStatusAdded/Changed

-- 1. Remove
-- 2. OnRemove
-- 3. Update
-- 4. OnStatusRemoved

-- TODO:
-- check replication for any desync
-- replicate when default property changes
-- properly handle client init request

--// Services \\--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Types \\--

export type SyncBehaviour = "SyncAllCharacters" | "SyncAllOwnedCharacters" | "SyncOwnerOnly" | "NoSync"

type Character = Model

type InternalStackType = number
type InternalApplyType = number

type ExposedStackType = "Set" | "Add" | "Multiply"
type ExposedApplyType = "Set" | "Stack"

export type StackType = InternalStackType | ExposedStackType
export type ApplyType = InternalApplyType | ExposedApplyType

-- Type for a single property effect
export type PropertyEffect<V = any> = {
	Value: V,
	StackType: StackType,
}

type InternalPropertyEffect<V = any> = {
	Value: V,
	StackType: InternalStackType,
}

-- Type for the status information passed to apply()
export type StatusInfo = {
	Priority: number?,
	Duration: number?,
	Timestamp: number?, -- used for synchronization
	StackCount: number?,

	RemainingDuration: number?, -- used for synchronization

	Tags: { string }?,
	Properties: { [string]: PropertyEffect }?,

	OnRemove: ((character: Character, removed: boolean) -> ())?, -- Optional callback when status is removed or expires
	OnTick: ((character: Character, deltaTime: number) -> ())?, -- Optional callback for periodic updates
}

type SanitizedStatusInfo = {
	Priority: number,
	Duration: number,
	Timestamp: number, -- used for synchronization
	StackCount: number,

	RemainingDuration: number, -- used for synchronization

	Tags: { string },
	Properties: { [string]: InternalPropertyEffect },

	OnRemove: ((character: Character, removed: boolean) -> ())?,
	OnTick: ((character: Character, deltaTime: number) -> ())?,
}

-- Internal type for active status tracking
type ActiveStatus = {
	StatusName: string,
	Priority: number,
	Duration: number,
	RemainingDuration: number,
	Timestamp: number,
	StackCount: number,

	Paused: boolean,

	Tags: { string },
	Properties: { [string]: InternalPropertyEffect },

	OnRemove: ((character: Character, removed: boolean) -> ())?,
	OnTick: ((character: Character, deltaTime: number) -> ())?,
}

-- Internal type for effect calculations
type EffectData<V = any> = {
	Value: V,
	StackType: InternalStackType,

	Priority: number,
	Timestamp: number,
}

type ClientSyncData = {
	Character: Character,
	Timestamp: number,
} & ({
	Action: "apply",
	StatusName: string,
	StatusInfo: StatusInfo,
	ApplyType: ApplyType?,
} | {
	Action: "remove",
	StatusName: string,
} | {
	Action: "clear",
} | {
	Action: "init",
	DefaultProperties: { [string]: any },
	CharacterId: number,
} | {
	Action: "pause",
	StatusName: string,
	StatusInfo: StatusInfo,
} | {
	Action: "resume",
	StatusName: string,
} | {
	Action: "modifyDuration",
	StatusName: string,
	NewDuration: number,
	StatusInfo: StatusInfo,
})

type syncPacket = buffer

type CharacterData = {
	Id: number,
	OwnedPlayer: Player?,
	ActiveStatuses: { ActiveStatus },
	DefaultProperties: { [string]: any },
	CustomHandlers: { [string]: (character: Character, property: string, value: any) -> () },
	Connection: RBXScriptConnection,
}

type initCharacterData = {
	Id: number,
	ActiveStatuses: { ActiveStatus },
	DefaultProperties: { [string]: any },
	Timestamp: number,
}

export type configModule = {
	DefaultProperties: { [string]: any }?,
	DefaultHandler: {
		[string]: (character: Character, value: any) -> (),
	}?,
	SyncBehaviour: SyncBehaviour?,
	AllowAttributesAsProperties: boolean?,
}

type disconnect = () -> ()

-- Main module type with proper function signatures
export type StatusModule = {
	-- Core API
	apply: (character: Character, statusName: string, statusInfo: StatusInfo, applyType: ApplyType?) -> (),
	remove: (character: Character, statusName: string, timestamp: number?) -> (),
	hasStatus: (character: Character, statusName: string) -> boolean,
	getActiveStatuses: (character: Character) -> { string },
	getStatusInfo: (character: Character, statusName: string) -> StatusInfo?,
	clearAllStatuses: (character: Character, timestamp: number?) -> (),

	-- Duration Management
	getRemainingDuration: (character: Character, statusName: string) -> number?,
	modifyDuration: (character: Character, statusName: string, newDuration: number) -> (),

	-- Pause/Resume
	pauseStatus: (character: Character, statusName: string) -> (),
	resumeStatus: (character: Character, statusName: string) -> (),
	pauseAllStatuses: (character: Character) -> (),
	resumeAllStatuses: (character: Character) -> (),

	-- Character Management
	initCharacter: (character: Character, defaultProperties: { [string]: any }?) -> (),
	removeCharacter: (character: Character) -> (),

	-- Tags
	getStatusesByTag: (character: Character, tag: string) -> { string },
	addTag: (character: Character, statusName: string, tag: string) -> (),
	removeTag: (character: Character, statusName: string, tag: string) -> (),

	-- Stack Management
	getStackCount: (character: Character, statusName: string) -> number?,
	addStack: (character: Character, statusName: string, count: number?) -> (),
	removeStack: (character: Character, statusName: string, count: number?) -> (),

	-- Properties
	getEffectiveProperty: (character: Character, property: string) -> any,
	getBaseProperty: (character: Character, property: string) -> any,
	setBaseProperty: (character: Character, property: string, value: any) -> (),
	setCustomHandler: (character: Character, property: string, handler: (character: Character, value: any) -> ()) -> (),
	removeCustomHandler: (character: Character, property: string) -> (),

	-- System
	advanceState: (deltaTime: number?) -> (),

	-- Events
	BindToStatusAdded: (callback: (character: Character, statusName: string, statusInfo: StatusInfo) -> ()) -> disconnect,
	BindToStatusRemoved: (callback: (character: Character, statusName: string, removed: boolean) -> ()) -> disconnect,
	BindToStatusChanged: (
		callback: (character: Character, statusName: string, oldStatusInfo: StatusInfo, newStatusInfo: StatusInfo) -> ()
	) -> disconnect,

	-- Enums
	StackType: { [ExposedStackType]: number },
	ApplyType: { [ExposedApplyType]: number },

	-- Config
	config: configModule?,
}

--// Constants \\--

local IS_SERVER = RunService:IsServer()

local STACK_TYPE_SET = 0
local STACK_TYPE_ADD = 1
local STACK_TYPE_MULTIPLY = 2

-- Enum values
local STACK_TYPE_ENUM: { [ExposedStackType]: number } = {
	Set = STACK_TYPE_SET,
	Add = STACK_TYPE_ADD,
	Multiply = STACK_TYPE_MULTIPLY,
}

local APPLY_TYPE_SET = 0
local APPLY_TYPE_STACK = 1

local APPLY_TYPE_ENUM: { [ExposedApplyType]: number } = {
	Set = APPLY_TYPE_SET,
	Stack = APPLY_TYPE_STACK,
}

-- Valid stack types
local VALID_STACK_TYPES: { [StackType]: boolean } = {}
local VALID_APPLY_TYPES: { [ApplyType]: boolean } = {}

for stackType, value in STACK_TYPE_ENUM do
	VALID_STACK_TYPES[stackType] = true
	VALID_STACK_TYPES[value] = true
end

for applyType, value in APPLY_TYPE_ENUM do
	VALID_APPLY_TYPES[applyType] = true
	VALID_APPLY_TYPES[value] = true
end

local DEFAULT_DURATION = math.huge
local DEFAULT_STACK_TYPE: InternalStackType = 0 -- "Set" as default stack type
local DEFAULT_APPLY_TYPE: InternalApplyType = 0 -- "Set" as default apply type
local DEFAULT_PRIORITY = 0
local DEFAULT_STACK_COUNT = 1

local DEFAULT_CONFIG: configModule = {
	DefaultProperties = {},
	DefaultHandler = {},
	SyncBehaviour = "SyncOwnerOnly",
}

local CLIENT_SYNC_REMOTE_NAME = "STATUS_HANDLER_ClientSync"
local INIT_REQUEST_REMOTE_NAME = "STATUS_HANDLER_InitRequest"
local EVENT_FOLDER_NAME = "STATUS_HANDLER_EventFolder"
local SYNC_FOLDER_NAME = "STATUS_HANDLER_SyncFolder"

-- Remote setup
local STATUS_SYNC_REMOTE: RemoteEvent
local SYNC_REQUEST_REMOTE: RemoteFunction
local EVENT_FOLDER: Folder
local SYNC_FOLDER: Folder

local REQUEST_DEFAULT_PROPERTIES = string.char(32)
local REQUEST_INIT_DATA = string.char(33)

if IS_SERVER then
	EVENT_FOLDER = ReplicatedStorage:FindFirstChild(EVENT_FOLDER_NAME) :: Folder? or Instance.new("Folder")
	assert(EVENT_FOLDER:IsA("Folder"), "EVENT_FOLDER must be a Folder")
	EVENT_FOLDER.Name = EVENT_FOLDER_NAME
	EVENT_FOLDER.Parent = ReplicatedStorage

	STATUS_SYNC_REMOTE = EVENT_FOLDER:FindFirstChild(CLIENT_SYNC_REMOTE_NAME) :: RemoteEvent? or Instance.new("RemoteEvent")
	assert(STATUS_SYNC_REMOTE:IsA("RemoteEvent"), "STATUS_SYNC_REMOTE must be a RemoteEvent")
	STATUS_SYNC_REMOTE.Name = CLIENT_SYNC_REMOTE_NAME
	STATUS_SYNC_REMOTE.Parent = EVENT_FOLDER

	SYNC_REQUEST_REMOTE = EVENT_FOLDER:FindFirstChild(INIT_REQUEST_REMOTE_NAME) :: RemoteFunction?
		or Instance.new("RemoteFunction")
	assert(SYNC_REQUEST_REMOTE:IsA("RemoteFunction"), "SYNC_REQUEST_REMOTE must be a RemoteFunction")
	SYNC_REQUEST_REMOTE.Name = INIT_REQUEST_REMOTE_NAME
	SYNC_REQUEST_REMOTE.Parent = EVENT_FOLDER

	SYNC_FOLDER = ReplicatedStorage:FindFirstChild(SYNC_FOLDER_NAME) :: Folder? or Instance.new("Folder")
	assert(SYNC_FOLDER:IsA("Folder"), "SYNC_FOLDER must be a Folder")
	SYNC_FOLDER.Name = SYNC_FOLDER_NAME
	SYNC_FOLDER.Parent = ReplicatedStorage
else
	EVENT_FOLDER = ReplicatedStorage:WaitForChild(EVENT_FOLDER_NAME) :: Folder
	assert(EVENT_FOLDER:IsA("Folder"), "EVENT_FOLDER must be a Folder")

	STATUS_SYNC_REMOTE = EVENT_FOLDER:WaitForChild(CLIENT_SYNC_REMOTE_NAME) :: RemoteEvent
	assert(STATUS_SYNC_REMOTE:IsA("RemoteEvent"), "STATUS_SYNC_REMOTE must be a RemoteEvent")
	SYNC_REQUEST_REMOTE = EVENT_FOLDER:WaitForChild(INIT_REQUEST_REMOTE_NAME) :: RemoteFunction
	assert(SYNC_REQUEST_REMOTE:IsA("RemoteFunction"), "SYNC_REQUEST_REMOTE must be a RemoteFunction")
	SYNC_FOLDER = ReplicatedStorage:WaitForChild(SYNC_FOLDER_NAME) :: Folder
	assert(SYNC_FOLDER:IsA("Folder"), "SYNC_FOLDER must be a Folder")
end

--// Variables \\--

local characterDataList: { [Model]: CharacterData } = {}

local statusCallbacks: { [string]: { <T...>(T...) -> () } } = {
	OnStatusAdded = {},
	OnStatusRemoved = {},
	OnStatusChanged = {},
}

--// Module \\--

local StatusModule = {} :: StatusModule

--// Utility Functions \\--

local function getTime(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function getConfig(): configModule
	return StatusModule.config or DEFAULT_CONFIG
end

local function getCharacterData(character: Character): CharacterData?
	return characterDataList[character]
end

local function ensureCharacterData(character: Character): CharacterData
	if not characterDataList[character] then StatusModule.initCharacter(character) end
	return characterDataList[character]
end

local findStatus = (
	function(character: Character, statusName: string)
		local characterData = getCharacterData(character)
		if not characterData then
			warn(`StatusModule: Cannot find status '{statusName}' - character data not initialized for '{character.Name}'.`)
			return nil
		end

		for i, status in characterData.ActiveStatuses do
			if status.StatusName == statusName then return i :: any, status end
		end

		return nil
	end
) :: ((character: Character, statusName: string) -> (number, ActiveStatus)) & ((character: Character, statusName: string) -> nil)

--// Config System \\--

local function getDefaultProperties(): { [string]: any }
	return getConfig().DefaultProperties or {}
end

--// Property Application \\--

local function indexObject(object: any, index: any): any
	return object[index]
end

local function safeGetObjectProperty(object: any, propertyName: string): (boolean, any)
	if getConfig().AllowAttributesAsProperties then
		local value = object:GetAttribute(propertyName)
		if value ~= nil then return true, value end
	end
	return pcall(indexObject, object, propertyName)
end

local function setObjectIndex(object: any, index: any, value: any): ()
	object[index] = value
end

local function safeSetObjectProperty(object: any, propertyName: string, value: any): (boolean, any)
	if getConfig().AllowAttributesAsProperties and object:GetAttribute(propertyName) ~= nil then
		object:SetAttribute(propertyName, value)
		return true
	end
	return pcall(setObjectIndex, object, propertyName, value)
end

local function applyPropertyToCharacter(character: Character, property: string, value: any): ()
	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot apply property '{property}' to character '{character.Name}' - character data not initialized.`)
		return
	end

	-- Check for custom handler
	if characterData.CustomHandlers[property] then
		characterData.CustomHandlers[property](character, property, value)
		return
	end

	-- Default humanoid property handling
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn(`StatusModule: Cannot apply property '{property}' to character '{character.Name}' - no Humanoid found.`)
		return
	end

	local success, result = safeSetObjectProperty(humanoid, property, value)
	if not success then
		warn(`StatusModule: Failed to set property '{property}' to {value} on character '{character.Name}': {result}`)
		return
	end
end

--// Sync Functions \\--

local currentId = 0

local function createSyncObject(character: Character): (ObjectValue, number)
	local characterId = currentId

	local syncObject = Instance.new("ObjectValue")
	syncObject.Name = tostring(characterId)
	syncObject.Value = character
	syncObject.Parent = SYNC_FOLDER

	currentId = currentId + 1
	return syncObject, characterId
end

local function writeSyncData(syncData: ClientSyncData): syncPacket
	return syncData :: any -- temporary
end

local function readSyncData(syncPacket: syncPacket): ClientSyncData
	return syncPacket :: any -- temporary
end

local function writeSyncRequestData(syncData: { initCharacterData }): syncPacket
	return syncData :: any -- temporary
end

local function readSyncRequestData(syncPacket: syncPacket): { initCharacterData }
	return syncPacket :: any -- temporary
end

local function syncStatusChange(syncData: ClientSyncData, targetPlayer: Player?)
	if not IS_SERVER then return end

	if targetPlayer then
		STATUS_SYNC_REMOTE:FireClient(targetPlayer, writeSyncData(syncData))
	else
		STATUS_SYNC_REMOTE:FireAllClients(writeSyncData(syncData))
	end
end

local function getCharacterFromSyncId(characterId: number): Character
	print(`getCharacterFromSyncId: {characterId}`)
	local syncObject = SYNC_FOLDER:WaitForChild(tostring(characterId)) :: ObjectValue
	local character = syncObject.Value or syncObject.Changed:Wait() :: Instance
	print(`getCharacterFromSyncId: Found character '{character.Name}' for ID '{characterId}'`)
	return character :: Character
end

--// Core Logic \\--

local function updateCharacter(character: Character): ()
	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot update character '{character.Name}' - character data not initialized.`)
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn(`StatusModule: Cannot update character '{character.Name}' - no Humanoid found.`)
		return
	end

	local statuses = characterData.ActiveStatuses

	-- If no statuses are active, revert to default properties
	if next(statuses) == nil then
		for property, value in characterData.DefaultProperties do
			applyPropertyToCharacter(character, property, value)
		end
		return
	end

	local baseProperties = characterData.DefaultProperties
	local processingProperties: { [string]: any } = table.clone(baseProperties)
	local setProperties: { [string]: any } = {}

	-- Statuses are already sorted on insertion, so we can process them in order
	for _, status in statuses do
		if status.Paused then continue end

		-- Gather all properties for this status
		for property, effect in status.Properties do
			if setProperties[property] ~= nil then continue end -- Property already finalized

			local stackType = effect.StackType
			local currentValue = processingProperties[property]
			if not currentValue then
				warn(
					`StatusModule: Property '{property}' not found in character '{character.Name}' default properties. Attempting to retrieve from Humanoid as fallback.`
				)
				local success, value = safeGetObjectProperty(humanoid, property)
				if not success then
					warn(`StatusModule: Failed to get property '{property}' from character '{character.Name}': {value}`)
					continue
				end

				baseProperties[property] = value
				processingProperties[property] = value
				currentValue = value
			end

			if stackType == STACK_TYPE_SET then
				setProperties[property] = effect.Value
			elseif stackType == STACK_TYPE_ADD then
				local success, result = pcall(function()
					processingProperties[property] = currentValue + effect.Value
					return nil
				end)
				if not success then
					warn(`StatusModule: Failed to add value to property '{property}' on character '{character.Name}': {result}`)
					continue
				end
			else -- STACK_TYPE_MULTIPLY
				local success, result = pcall(function()
					processingProperties[property] = currentValue + baseProperties[property] * (effect.Value - 1)
					return nil
				end)
				if not success then
					warn(
						`StatusModule: Failed to multiply value for property '{property}' on character '{character.Name}': {result}`
					)
					continue
				end
			end
		end
	end

	-- Apply all calculated properties
	for property, value in setProperties do
		applyPropertyToCharacter(character, property, value)
	end

	-- Apply any remaining processing properties
	for property, value in processingProperties do
		applyPropertyToCharacter(character, property, value)
	end
end

local function initCharacter(character: Model, defaultProperties: { [string]: any }?, sync: boolean?): ()
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot initialize character - invalid character model provided.")
		return
	end

	if characterDataList[character] then return end

	if defaultProperties ~= nil then
		if type(defaultProperties) ~= "table" then
			warn("StatusModule: Cannot initialize character - defaultProperties must be a table.")
			return
		else
			for property in defaultProperties do
				if type(property) ~= "string" then
					warn(
						`StatusModule: Invalid property '{property}' in defaultProperties for character '{character.Name}'. Must be a string.`
					)
					return
				end
			end
		end
	elseif not IS_SERVER then
		error("cannot init character from client, not implemented yet")
		-- defaultProperties = SYNC_REQUEST_REMOTE:InvokeServer(REQUEST_DEFAULT_PROPERTIES, character)
	end

	local properties = defaultProperties :: { [string]: any } or getDefaultProperties()

	local characterData = {
		Id = 0,
		OwnedPlayer = Players:GetPlayerFromCharacter(character),
		ActiveStatuses = {},
		DefaultProperties = properties,
		CustomHandlers = {},
		Connection = character.AncestryChanged:Connect(function()
			if not character:IsDescendantOf(game) then StatusModule.removeCharacter(character) end
		end),
	}

	characterDataList[character] = characterData :: CharacterData

	if IS_SERVER and sync ~= false then
		-- Create sync object for replication
		local _, id = createSyncObject(character)
		characterData.Id = id

		syncStatusChange({
			Action = "init" :: "init",
			Character = character,
			DefaultProperties = properties,
			CharacterId = id,
			Timestamp = getTime(),
		})
	end
end

--// Public API \\--

function StatusModule.apply(character: Character, statusName: string, statusInfo: StatusInfo, applyType: ApplyType?): ()
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot apply status - invalid character model provided.")
		return
	end

	if not statusName or statusName == "" then
		warn("StatusModule: Cannot apply status - statusName cannot be nil or empty.")
		return
	end

	if not statusInfo then
		warn("StatusModule: Cannot apply status - statusInfo cannot be nil.")
		return
	end

	if type(applyType) == "number" then
		if not VALID_APPLY_TYPES[applyType] then
			warn(`StatusModule: Invalid apply type '{applyType}' for status '{statusName}'.`)
			return
		end
	elseif type(applyType) == "string" then
		local normalized = APPLY_TYPE_ENUM[applyType]
		if not normalized then
			warn(`StatusModule: Invalid apply type '{applyType}' for status '{statusName}'.`)
			return
		end
		applyType = normalized
	elseif applyType ~= nil then
		warn(`StatusModule: Invalid apply type '{applyType}' for status '{statusName}'. Using default apply type.`)
		return
	else
		applyType = DEFAULT_APPLY_TYPE
	end

	local characterData = ensureCharacterData(character)
	local statuses = characterData.ActiveStatuses

	local duration = statusInfo.Duration or DEFAULT_DURATION
	if duration < 0 then
		warn(`StatusModule: Cannot apply status '{statusName}' - Duration cannot be negative.`)
		return
	end

	local sanitizedStatusInfo: SanitizedStatusInfo = table.clone(statusInfo) :: any
	sanitizedStatusInfo.Duration = duration

	if statusInfo.RemainingDuration ~= nil then
		if type(statusInfo.RemainingDuration) ~= "number" or statusInfo.RemainingDuration < 0 then
			warn(
				`StatusModule: Invalid RemainingDuration '{statusInfo.RemainingDuration}' for status '{statusName}'. Using Duration.`
			)
			sanitizedStatusInfo.RemainingDuration = duration
		else
			sanitizedStatusInfo.RemainingDuration = statusInfo.RemainingDuration
		end
	else
		sanitizedStatusInfo.RemainingDuration = duration
	end

	-- Normalize and validate properties
	local sanitizedProperties: { [string]: InternalPropertyEffect } = {}
	if statusInfo.Properties then
		for propName, propInfo in statusInfo.Properties do
			if type(propInfo) ~= "table" then
				warn(`StatusModule: Invalid property '{propName}' for status '{statusName}' - must be a table.`)
				continue
			end

			local stackType = propInfo.StackType or DEFAULT_STACK_TYPE
			if type(stackType) == "number" then
				if not VALID_STACK_TYPES[stackType] then stackType = nil end
			elseif type(stackType) == "string" then
				stackType = STACK_TYPE_ENUM[stackType]
			end

			if not stackType then
				warn(
					`StatusModule: Invalid stack type '{stackType}' for property '{propName}' in status '{statusName}'. Using default stack type.`
				)
			end

			sanitizedProperties[propName] = {
				Value = propInfo.Value,
				StackType = stackType :: number? or DEFAULT_STACK_TYPE,
			}
		end
	end

	sanitizedStatusInfo.Properties = sanitizedProperties

	local priority = statusInfo.Priority
	if priority ~= nil and (type(priority) ~= "number" or priority ~= priority) then
		warn(`StatusModule: Invalid priority '{priority}' for status '{statusName}'. Using default priority.`)
		priority = nil
	end

	sanitizedStatusInfo.Priority = priority or DEFAULT_PRIORITY

	local timestamp = statusInfo.Timestamp
	if timestamp ~= nil and (type(timestamp) ~= "number" or timestamp ~= timestamp) then
		warn(`StatusModule: Invalid timestamp '{timestamp}' for status '{statusName}'. Using current time.`)
		timestamp = nil
	end

	sanitizedStatusInfo.Timestamp = timestamp or getTime()

	local tags = statusInfo.Tags
	if tags ~= nil and type(tags) ~= "table" then
		warn(`StatusModule: Invalid tags '{tags}' for status '{statusName}'. Using empty tags.`)
	end

	sanitizedStatusInfo.Tags = tags or {}

	local stackCount = statusInfo.StackCount
	if stackCount ~= nil and type(stackCount) ~= "number" then
		warn(`StatusModule: Invalid stack count '{stackCount}' for status '{statusName}'. Using default stack count.`)
		stackCount = nil
	end

	sanitizedStatusInfo.StackCount = stackCount or DEFAULT_STACK_COUNT

	if statusInfo.OnRemove ~= nil and type(statusInfo.OnRemove) ~= "function" then
		warn(`StatusModule: Invalid OnRemove callback for status '{statusName}'. Using nil.`)
		sanitizedStatusInfo.OnRemove = nil
	end

	if statusInfo.OnTick ~= nil and type(statusInfo.OnTick) ~= "function" then
		warn(`StatusModule: Invalid OnTick callback for status '{statusName}'. Using nil.`)
		sanitizedStatusInfo.OnTick = nil
	end

	local currentTime = sanitizedStatusInfo.Timestamp

	local _, existingStatus = findStatus(character, statusName)
	local oldStatusInfo = nil

	if existingStatus then
		oldStatusInfo = {
			Priority = existingStatus.Priority,
			Duration = existingStatus.Duration,
			Timestamp = existingStatus.Timestamp,
			StackCount = existingStatus.StackCount,

			Tags = table.clone(existingStatus.Tags),
			Properties = table.clone(existingStatus.Properties),

			OnRemove = existingStatus.OnRemove,
			OnTick = existingStatus.OnTick,
		}

		if applyType == APPLY_TYPE_STACK then
			-- Add to existing stack
			existingStatus.StackCount = existingStatus.StackCount + sanitizedStatusInfo.StackCount
			existingStatus.RemainingDuration = duration
		else
			if applyType ~= APPLY_TYPE_SET then
				warn(`StatusModule: Invalid apply type '{applyType}' for status '{statusName}'. Using default apply type.`)
			end
			-- Replace existing status
			existingStatus.Priority = priority or DEFAULT_PRIORITY
			existingStatus.Duration = duration
			existingStatus.RemainingDuration = duration
			existingStatus.Properties = sanitizedProperties
			existingStatus.Timestamp = currentTime
			existingStatus.Tags = sanitizedStatusInfo.Tags
			existingStatus.StackCount = sanitizedStatusInfo.StackCount
			existingStatus.OnRemove = sanitizedStatusInfo.OnRemove
			existingStatus.OnTick = sanitizedStatusInfo.OnTick
		end
	else
		-- Create new status
		local statusPriority = sanitizedStatusInfo.Priority
		local inserted = false

		local newStatus = {
			StatusName = statusName,
			Priority = statusPriority,
			Duration = duration,
			RemainingDuration = sanitizedStatusInfo.RemainingDuration,
			Timestamp = currentTime,
			StackCount = sanitizedStatusInfo.StackCount,

			Paused = false,

			Tags = sanitizedStatusInfo.Tags,
			Properties = sanitizedProperties,

			OnRemove = sanitizedStatusInfo.OnRemove,
			OnTick = sanitizedStatusInfo.OnTick,
		}

		for i, status in statuses do
			if status.Priority > statusPriority then continue end
			if status.Priority == statusPriority and status.Timestamp < currentTime then
				-- If same priority, keep the first applied one
				continue
			end
			table.insert(statuses, i, newStatus)
			inserted = true
			break
		end

		if not inserted then table.insert(statuses, newStatus) end
	end

	updateCharacter(character)

	-- Fire events
	if oldStatusInfo then
		for _, callback in statusCallbacks.OnStatusChanged do
			task.spawn(callback, character, statusName, oldStatusInfo, statusInfo)
		end
	else
		for _, callback in statusCallbacks.OnStatusAdded do
			task.spawn(callback, character, statusName, statusInfo)
		end
	end

	if IS_SERVER then
		syncStatusChange({
			Action = "apply" :: "apply",
			Character = character,
			Timestamp = currentTime,
			StatusName = statusName :: string,
			StatusInfo = statusInfo,
			ApplyType = applyType,
		})
	end
end

function StatusModule.remove(character: Character, statusName: string, timestamp: number?)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot remove status - invalid character model provided.")
		return
	end

	if not statusName or statusName == "" then
		warn("StatusModule: Cannot remove status - statusName cannot be nil or empty.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot remove status '{statusName}' - character data not initialized for '{character.Name}'.`)
		return
	end

	local statuses = characterData.ActiveStatuses
	local index, existingStatus = findStatus(character, statusName)

	if not existingStatus then return end

	if timestamp and existingStatus.Timestamp > timestamp then
		return -- Ignore older remove requests
	end

	table.remove(statuses, index)

	local onRemove = existingStatus.OnRemove
	if onRemove then task.spawn(onRemove, character, true) end

	updateCharacter(character)

	for _, callback in statusCallbacks.OnStatusRemoved do
		task.spawn(callback, character, statusName, true)
	end

	if IS_SERVER then
		syncStatusChange({
			Action = "remove" :: "remove",
			Character = character,
			StatusName = statusName :: string,
			Timestamp = getTime(),
		})
	end
end

function StatusModule.hasStatus(character: Character, statusName: string): boolean
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot check status - invalid character model provided.")
		return false
	end

	if type(statusName) ~= "string" or statusName == "" then
		warn("StatusModule: Cannot check status - statusName must be a non-empty string.")
		return false
	end

	return findStatus(character, statusName) ~= nil
end

function StatusModule.getActiveStatuses(character: Character): { string }
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get active statuses - invalid character model provided.")
		return {}
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get active statuses - character data not initialized for '{character.Name}'.`)
		return {}
	end

	local statusNames = {}
	for _, status in characterData.ActiveStatuses do
		table.insert(statusNames, status.StatusName)
	end

	return statusNames
end

function StatusModule.getStatusInfo(character: Character, statusName: string): StatusInfo?
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get status info - invalid character model provided.")
		return nil
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get status info - character data not initialized for '{character.Name}'.`)
		return nil
	end

	local _, status = findStatus(character, statusName)
	if not status then return nil end

	return {
		Priority = status.Priority,
		Duration = status.Duration,
		Timestamp = status.Timestamp,
		StackCount = status.StackCount,

		Tags = table.clone(status.Tags),
		Properties = table.clone(status.Properties) :: { [string]: PropertyEffect },

		OnRemove = status.OnRemove,
		OnTick = status.OnTick,
	}
end

function StatusModule.clearAllStatuses(character: Character, timestamp: number?)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot clear statuses - invalid character model provided.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot clear statuses - character data not initialized for '{character.Name}'.`)
		return
	end

	local statuses = characterData.ActiveStatuses
	local removedAny = false

	if timestamp then
		for i = #statuses, 1, -1 do
			local status = statuses[i]
			if status.Timestamp > timestamp then continue end
			table.remove(statuses, i)
			removedAny = true
			for _, callback in statusCallbacks.OnStatusRemoved do
				task.spawn(callback, character, status.StatusName, true)
			end
		end
	else
		local clone = table.clone(statuses)
		table.clear(statuses)

		for _, status in clone do
			local onRemove = status.OnRemove
			if onRemove then task.spawn(onRemove, character, true) end
			for _, callback in statusCallbacks.OnStatusRemoved do
				task.spawn(callback, character, status.StatusName, true)
			end
		end

		removedAny = true
	end

	if removedAny then
		updateCharacter(character)

		if IS_SERVER then
			syncStatusChange({
				Action = "clear" :: "clear",
				Character = character,
				Timestamp = timestamp or getTime(),
			})
		end
	end
end

function StatusModule.getRemainingDuration(character: Character, statusName: string): number?
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot modify duration - invalid character model provided.")
		return nil
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot modify duration - character data not initialized for '{character.Name}'.`)
		return nil
	end

	local _, status = findStatus(character, statusName)
	if not status then return nil end

	if status.Duration == math.huge then return math.huge end
	return math.max(0, status.RemainingDuration)
end

function StatusModule.modifyDuration(character: Character, statusName: string, newDuration: number)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot modify duration - invalid character model provided.")
		return
	end

	if type(newDuration) ~= "number" or newDuration < 0 then
		warn(
			`StatusModule: Invalid new duration '{newDuration}' for status '{statusName}'. Duration must be a non-negative number.`
		)
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot modify duration - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot modify duration - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	local oldDuration = status.Duration
	if oldDuration == newDuration then return end

	status.Duration = newDuration
	status.RemainingDuration = status.Duration

	if IS_SERVER then
		syncStatusChange({
			Action = "modifyDuration" :: "modifyDuration",
			Character = character,
			StatusName = statusName :: string,
			StatusInfo = status :: StatusInfo,
			NewDuration = newDuration,
			Timestamp = getTime(),
		})
	end
end

function StatusModule.pauseStatus(character: Character, statusName: string)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot pause status - invalid character model provided.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot pause status - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot pause status - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	if status.Paused then return end
	status.Paused = true
	updateCharacter(character)

	if IS_SERVER then
		syncStatusChange({
			Action = "pause" :: "pause",
			Character = character,
			StatusName = statusName :: string,
			StatusInfo = status :: StatusInfo,
			Timestamp = getTime(),
		})
	end
end

function StatusModule.resumeStatus(character: Character, statusName: string)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot resume status - invalid character model provided.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot resume status - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot resume status - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	if not status.Paused then return end

	status.Paused = false
	updateCharacter(character)

	if IS_SERVER then
		syncStatusChange({
			Action = "resume" :: "resume",
			Character = character,
			StatusName = statusName,
			Timestamp = getTime(),
		})
	end
end

function StatusModule.pauseAllStatuses(character: Character)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot pause all statuses - invalid character model provided.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot pause all statuses - character data not initialized for '{character.Name}'.`)
		return
	end

	for _, status in characterData.ActiveStatuses do
		StatusModule.pauseStatus(character, status.StatusName)
	end
end

function StatusModule.resumeAllStatuses(character: Character)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot resume all statuses - invalid character model provided.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot resume all statuses - character data not initialized for '{character.Name}'.`)
		return
	end

	for _, status in characterData.ActiveStatuses do
		StatusModule.resumeStatus(character, status.StatusName)
	end
end

StatusModule.initCharacter = initCharacter :: any

function StatusModule.removeCharacter(character: Character)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot remove character - invalid character model provided.")
		return
	end

	local characterData = characterDataList[character]
	if not characterData then return end

	-- Reset properties if character still exists
	if character.Parent then
		for property, value in characterData.DefaultProperties do
			applyPropertyToCharacter(character, property, value)
		end
	end

	-- Clean up connections
	if characterData.Connection then characterData.Connection:Disconnect() end
	local syncObject = SYNC_FOLDER:FindFirstChild(tostring(characterData.Id))
	if syncObject then syncObject:Destroy() end

	characterDataList[character] = nil
end

function StatusModule.getStatusesByTag(character: Character, tag: string): { string }
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get statuses by tag - invalid character model provided.")
		return {}
	end

	if type(tag) ~= "string" or tag == "" then
		warn("StatusModule: Cannot get statuses by tag - tag must be a non-empty string.")
		return {}
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get statuses by tag - character data not initialized for '{character.Name}'.`)
		return {}
	end

	local result = {}
	for _, status in characterData.ActiveStatuses do
		if table.find(status.Tags, tag) then table.insert(result, status.StatusName) end
	end

	return result
end

function StatusModule.addTag(character: Character, statusName: string, tag: string)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot add tag - invalid character model provided.")
		return
	end

	if type(statusName) ~= "string" or statusName == "" then
		warn("StatusModule: Cannot add tag - statusName must be a non-empty string.")
		return
	end

	if type(tag) ~= "string" or tag == "" then
		warn("StatusModule: Cannot add tag - tag must be a non-empty string.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot add tag - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot add tag - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	if not table.find(status.Tags, tag) then table.insert(status.Tags, tag) end
end

function StatusModule.removeTag(character: Character, statusName: string, tag: string)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot remove tag - invalid character model provided.")
		return
	end

	if type(statusName) ~= "string" or statusName == "" then
		warn("StatusModule: Cannot remove tag - statusName must be a non-empty string.")
		return
	end

	if type(tag) ~= "string" or tag == "" then
		warn("StatusModule: Cannot remove tag - tag must be a non-empty string.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot remove tag - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot remove tag - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	local index = table.find(status.Tags, tag)
	if index then table.remove(status.Tags, index) end
end

function StatusModule.getStackCount(character: Character, statusName: string): number?
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get stack count - invalid character model provided.")
		return nil
	end

	if type(statusName) ~= "string" or statusName == "" then
		warn("StatusModule: Cannot get stack count - statusName must be a non-empty string.")
		return nil
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get stack count - character data not initialized for '{character.Name}'.`)
		return nil
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot get stack count - status '{statusName}' not found for character '{character.Name}'.`)
		return nil
	end

	return status.StackCount
end

function StatusModule.addStack(character: Character, statusName: string, count: number?)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot add stack - invalid character model provided.")
		return
	end

	if type(statusName) ~= "string" or statusName == "" then
		warn("StatusModule: Cannot add stack - statusName must be a non-empty string.")
		return
	end

	if count ~= nil and type(count) ~= "number" then
		warn("StatusModule: Cannot add stack - count must be a number or nil.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot add stack - character data not initialized for '{character.Name}'.`)
		return
	end

	local _, status = findStatus(character, statusName)
	if not status then
		warn(`StatusModule: Cannot add stack - status '{statusName}' not found for character '{character.Name}'.`)
		return
	end

	status.StackCount = status.StackCount + (count or 1)
	if status.StackCount <= 0 then
		StatusModule.remove(character, statusName)
		return
	end
	updateCharacter(character)
end

function StatusModule.removeStack(character: Character, statusName: string, count: number?)
	if count ~= nil and type(count) ~= "number" then
		warn("StatusModule: Cannot remove stack - count must be a number or nil.")
		return
	end
	return StatusModule.addStack(character, statusName, -(count or 1))
end

function StatusModule.getEffectiveProperty(character: Character, property: string): any
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get effective property - invalid character model provided.")
		return nil
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get effective property - character data not initialized for '{character.Name}'.`)
		return nil
	end

	local baseValue = characterData.DefaultProperties[property]
	if baseValue == nil then
		warn(
			`StatusModule: Cannot get effective property - property '{property}' not found in character '{character.Name}' default properties.`
		)
		return nil
	end

	-- Same calculation logic as updateCharacter but for single property
	local effectiveValue

	for _, status in characterData.ActiveStatuses do
		if status.Paused then continue end
		local effect = status.Properties[property]
		if not effect then continue end

		local stackType = effect.StackType

		if not effectiveValue then
			if effect.StackType == STACK_TYPE_SET then
				return effect.Value -- Set overrides all other effects
			end
			effectiveValue = baseValue
		end

		if stackType == STACK_TYPE_ADD then
			effectiveValue = effectiveValue + effect.Value
		elseif stackType == STACK_TYPE_MULTIPLY then
			effectiveValue = effectiveValue + baseValue * (effect.Value - 1)
		end
	end

	return effectiveValue or baseValue
end

function StatusModule.getBaseProperty(character: Character, property: string): any
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot get base property - invalid character model provided.")
		return nil
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot get base property - character data not initialized for '{character.Name}'.`)
		return nil
	end

	return characterData.DefaultProperties[property]
end

function StatusModule.setBaseProperty(character: Character, property: string, value: any): ()
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot set base property - invalid character model provided.")
		return
	end

	if type(property) ~= "string" or property == "" then
		warn("StatusModule: Cannot set base property - property must be a non-empty string.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot set base property - character data not initialized for '{character.Name}'.`)
		return
	end
	characterData.DefaultProperties[property] = value

	updateCharacter(character)
end

function StatusModule.setCustomHandler(
	character: Character,
	property: string,
	handler: (character: Character, property: string, value: any) -> ()
)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot set custom handler - invalid character model provided.")
		return
	end

	if type(property) ~= "string" or property == "" then
		warn("StatusModule: Cannot set custom handler - property must be a non-empty string.")
		return
	end

	if type(handler) ~= "function" then
		warn("StatusModule: Cannot set custom handler - handler must be a function.")
		return
	end

	local characterData = ensureCharacterData(character)
	characterData.CustomHandlers[property] = handler
end

function StatusModule.removeCustomHandler(character: Character, property: string)
	if not (character and typeof(character) == "Instance" and character:IsA("Model")) then
		warn("StatusModule: Cannot remove custom handler - invalid character model provided.")
		return
	end

	if type(property) ~= "string" or property == "" then
		warn("StatusModule: Cannot remove custom handler - property must be a non-empty string.")
		return
	end

	local characterData = getCharacterData(character)
	if not characterData then
		warn(`StatusModule: Cannot remove custom handler - character data not initialized for '{character.Name}'.`)
		return
	end

	characterData.CustomHandlers[property] = nil
end

function StatusModule.advanceState(deltaTime: number?)
	local dt = deltaTime or 0

	for character, characterData in characterDataList do
		for i = #characterData.ActiveStatuses, 1, -1 do
			local status = characterData.ActiveStatuses[i]
			if status.Paused then continue end

			local onTick = status.OnTick
			if onTick then task.spawn(onTick, character, dt) end

			if status.Duration == math.huge then
				-- Infinite duration, no need to update
				continue
			end

			status.RemainingDuration = status.RemainingDuration - dt
			if status.RemainingDuration > 0 then continue end

			table.remove(characterData.ActiveStatuses, i)

			local onRemove = status.OnRemove
			if onRemove then task.spawn(onRemove, character, false) end

			updateCharacter(character)

			for _, callback in statusCallbacks.OnStatusRemoved do
				task.spawn(callback, character, status.StatusName, false)
			end

			if IS_SERVER then
				syncStatusChange({
					Action = "remove" :: "remove",
					Character = character,
					StatusName = status.StatusName,
					Timestamp = getTime(),
				})
			end
		end
	end
end

function StatusModule.BindToStatusAdded(
	callback: (character: Character, statusName: string, statusInfo: StatusInfo) -> ()
): disconnect
	if type(callback) ~= "function" then error("StatusModule: Cannot bind to status added - callback must be a function.", 2) end
	table.insert(statusCallbacks.OnStatusAdded, callback)

	local disconnected = false
	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(statusCallbacks.OnStatusAdded, callback)
		if index then table.remove(statusCallbacks.OnStatusAdded, index) end
	end
end

function StatusModule.BindToStatusChanged(callback: (
	character: Character,
	statusName: string,
	oldStatusInfo: StatusInfo?,
	newStatusInfo: StatusInfo
) -> ()): disconnect
	if type(callback) ~= "function" then
		error("StatusModule: Cannot bind to status changed - callback must be a function.", 2)
	end
	table.insert(statusCallbacks.OnStatusChanged, callback)

	local disconnected = false
	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(statusCallbacks.OnStatusChanged, callback)
		if index then table.remove(statusCallbacks.OnStatusChanged, index) end
	end
end

function StatusModule.BindToStatusRemoved(
	callback: (character: Character, statusName: string, removedByUser: boolean) -> ()
): disconnect
	if type(callback) ~= "function" then
		error("StatusModule: Cannot bind to status removed - callback must be a function.", 2)
	end
	table.insert(statusCallbacks.OnStatusRemoved, callback)

	local disconnected = false
	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(statusCallbacks.OnStatusRemoved, callback)
		if index then table.remove(statusCallbacks.OnStatusRemoved, index) end
	end
end

-- Enums
StatusModule.StackType = STACK_TYPE_ENUM
StatusModule.ApplyType = APPLY_TYPE_ENUM

--// Connections \\--

RunService.Heartbeat:Connect(StatusModule.advanceState)

--// Server Sync Handling \\--

if IS_SERVER then
	local function handleSyncRequest(player: Player, targetCharacter: Character?): { initCharacterData }?
		local config = getConfig()

		if config.SyncBehaviour == "NoSync" then
			warn("StatusModule: Sync behaviour is set to 'NoSync'. Cannot request sync data.")
			return nil
		end

		if config.SyncBehaviour == "SyncAllCharacters" then
			local syncList = {}
			for character, characterData in characterDataList do
				table.insert(syncList, {
					Id = characterData.Id,
					ActiveStatuses = table.clone(characterData.ActiveStatuses),
					DefaultProperties = table.clone(characterData.DefaultProperties),
					Timestamp = getTime(),
				})
			end

			return syncList
		elseif config.SyncBehaviour == "SyncAllOwnedCharacters" then
			local syncList = {}
			for _, characterData in characterDataList do
				if not characterData.OwnedPlayer then continue end
				table.insert(syncList, {
					Id = characterData.Id,
					ActiveStatuses = table.clone(characterData.ActiveStatuses),
					DefaultProperties = table.clone(characterData.DefaultProperties),
					Timestamp = getTime(),
				})
			end

			return syncList
		else -- SyncOwnerOnly (default)
			local character = player.Character
			if not character then return nil end

			local characterData = characterDataList[character]
			if not characterData then
				-- Initialize and return default properties
				StatusModule.initCharacter(character)
				characterData = characterDataList[character]
			end

			return {
				{
					Id = characterData.Id,
					ActiveStatuses = table.clone(characterData.ActiveStatuses),
					DefaultProperties = table.clone(characterData.DefaultProperties),
					Timestamp = getTime(),
				} :: initCharacterData,
			}
		end
	end

	SYNC_REQUEST_REMOTE.OnServerInvoke = function(player: Player, flag: string, ...): syncPacket?
		if flag == REQUEST_INIT_DATA then
			local result = handleSyncRequest(player, ...)
			if not result then return nil end

			return writeSyncRequestData(result)
		elseif flag == REQUEST_DEFAULT_PROPERTIES then
			error("StatusModule: REQUEST_DEFAULT_PROPERTIES is not supported in server sync requests.", 2)
		else
			error(`StatusModule: Unknown sync request flag '{flag}'.`, 2)
		end
	end
else
	-- Client sync handling
	STATUS_SYNC_REMOTE.OnClientEvent:Connect(function(syncPacket: syncPacket)
		local syncData = readSyncData(syncPacket)
		local action = syncData.Action

		if not action then return end

		if syncData.Action == "init" then
			local character = getCharacterFromSyncId(syncData.CharacterId)
			StatusModule.initCharacter(character, syncData.DefaultProperties)
		elseif syncData.Action == "apply" then
			StatusModule.apply(syncData.Character, syncData.StatusName, syncData.StatusInfo, syncData.ApplyType)
		elseif syncData.Action == "remove" then
			StatusModule.remove(syncData.Character, syncData.StatusName, syncData.Timestamp)
		elseif syncData.Action == "clear" then
			StatusModule.clearAllStatuses(syncData.Character, syncData.Timestamp)
		elseif syncData.Action == "pause" then
			if StatusModule.hasStatus(syncData.Character, syncData.StatusName) then
				StatusModule.pauseStatus(syncData.Character, syncData.StatusName)
			else
				local statusInfo = syncData.StatusInfo
				StatusModule.apply(syncData.Character, syncData.StatusName, statusInfo, APPLY_TYPE_SET)
			end
		elseif syncData.Action == "resume" then
			StatusModule.resumeStatus(syncData.Character, syncData.StatusName)
		elseif syncData.Action == "modifyDuration" then
			if StatusModule.hasStatus(syncData.Character, syncData.StatusName) then
				StatusModule.modifyDuration(syncData.Character, syncData.StatusName, syncData.NewDuration)
			else
				local statusInfo = syncData.StatusInfo
				StatusModule.apply(syncData.Character, syncData.StatusName, statusInfo, APPLY_TYPE_SET)
			end
		end
	end)

	do
		-- Request initial sync for local player character
		local syncPacket: buffer? = SYNC_REQUEST_REMOTE:InvokeServer(REQUEST_INIT_DATA)
		if syncPacket then
			local function init(characterData: initCharacterData)
				local character = getCharacterFromSyncId(characterData.Id)
				local activeStatuses = characterData.ActiveStatuses
				local defaultProperties = characterData.DefaultProperties

				StatusModule.initCharacter(character, defaultProperties)
				for _, status in activeStatuses do
					StatusModule.apply(character, status.StatusName, {
						Priority = status.Priority,
						Duration = status.Duration,
						Timestamp = status.Timestamp,
						StackCount = status.StackCount,
						Tags = status.Tags,
						Properties = status.Properties :: { [string]: PropertyEffect },
					}, APPLY_TYPE_SET)
				end
			end

			local syncData = readSyncRequestData(syncPacket)

			for _, characterData in syncData do
				task.spawn(init, characterData)
			end
		end
	end
end

--// Return \\--

return StatusModule
