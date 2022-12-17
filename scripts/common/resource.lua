--- Hammerstone: resource.lua.
-- Mostly used to extend the resource module with additional helpers.
-- @author SirLich

local mod = {
	-- A low load-order makes the most since, as we need these methods to be available
	-- for other shadows.
	loadOrder = 0
}

-- Sapiens
local typeMaps = mjrequire "common/typeMaps"

-- Hammerstone
local objectManager = mjrequire "hammerstone/object/objectManager"

function mod:onload(resource)
	--- Allows adding a resource.
	--- @param key: The key to add, such as 'cake'
	--- @param objectType: The object to add, containing all fields.
	function resource:addResource(key, objectType)
		local typeIndexMap = typeMaps.types.resources -- Created automatically in resource.lua

		local index = typeIndexMap[key]
		if not index then
			mj:error("Attempt to add resource type that isn't in typeIndexMap:", key)
		else
			if resource.types[key] then
				mj:warn("Overwriting resource type:", key)
				mj:log(debug.traceback())
			end
	
			objectType.key = key
			objectType.index = index
			typeMaps:insert("resource", resource.types, objectType)

			-- Recache the type maps
			resource.validTypes = typeMaps:createValidTypesArray("resource", resource.types)
		end

		return index
	end

	-- From the source code of version 0.3.8. It's a local function so copy/paste is the only way to use it :/
	local function createGroupHashesForBuiltInTypes()
		local validGroupTypes = typeMaps:createValidTypesArray("resourceGroup", resource.groups)
		for i,groupType in ipairs(validGroupTypes) do
			if not groupType.containsTypesSet then
				groupType.containsTypesSet = {}
			end
			for j, resourceTypeIndex in ipairs(groupType.resourceTypes) do
				groupType.containsTypesSet[resourceTypeIndex] = true
			end
		end
	end

	--- Allows adding a resource group.
	--- @param key: The key to add, such as 'cake'
	--- @param objectType: The object to add, containing all fields.
	function resource:addResourceGroup(key, objectType)
		local typeIndexMap = typeMaps.types.resourceGroups -- Created automatically in resource.lua

		local index = typeIndexMap[key]
		if not index then
			mj:error("Attempt to add resource group type that isn't in typeIndexMap:", key)
		else
			if resource.groups[key] then
				mj:warn("Overwriting resource group type:", key)
				mj:log(debug.traceback())
			end
	
			objectType.key = key
			objectType.index = index
			typeMaps:insert("resourceGroup", resource.groups, objectType)

			-- Recache the type maps
			createGroupHashesForBuiltInTypes()
		end

		return index
	end

	objectManager:generateResourceDefinitions(resource)
end

return mod
