--- Hammerstone: objectManager.lua
-- This module controlls the registration of all Data Driven API objects. 
-- It will search the filesystem for mod files which should be loaded, and then
-- interact with Sapiens to create the objects.
-- @author SirLich, earmuffs

local objectManager = {
	inspectCraftPanelData = {},

	-- Map between storage identifiers and object IDENTIFIERS that should use this storage.
	-- Collected when generating objects, and inserted when generating storages (after converting to index)
	-- @format map<string, array<string>>.
	objectsForStorage = {},
}

-- Sapiens
local rng = mjrequire "common/randomNumberGenerator"

-- Math
local mjm = mjrequire "common/mjm"
local vec2 = mjm.vec2
local vec3 = mjm.vec3
local mat3Identity = mjm.mat3Identity
local mat3Rotate = mjm.mat3Rotate

-- Hammerstone
local log = mjrequire "hammerstone/logging"
local utils = mjrequire "hammerstone/object/objectUtils" -- TOOD: Are we happy name-bungling imports?
local moduleManager = mjrequire "hammerstone/state/moduleManager"
local configLoader = mjrequire "hammerstone/object/configLoader"
local objectDB = configLoader.configs


---------------------------------------------------------------------------------
-- Configuation and Loading
---------------------------------------------------------------------------------

--- Data structure which defines how a config is loaded, and in which order. 
-- @field configSource - Table to store loaded config data.
-- @field configPath - Path to the folder where the config files can be read. Multiple objects can be generated from the same file.
-- Each route here maps to a FILE TYPE. The fact that 
-- file type has no impact herre.
-- @field moduleDependencies - Table list of modules which need to be loaded before this type of config is loaded
-- @field loaded - Whether the route has already been loaded
-- @field loadFunction - Function which is called when the config type will be loaded. Must take in a single param: the config to load!
-- @field waitingForStart - Whether this config is waiting for a custom trigger or not.
local objectLoader = {

	storage = {
		configSource = objectDB.storageConfigs,
		configPath = "/hammerstone/storage/",
		moduleDependencies = {
			"storage"
		},
		loadFunction = "generateStorageObject" -- TODO: Find out how to run a function without accessing it via string
	},

	evolvingObject = {
		configSource = objectDB.objectConfigs,
		waitingForStart = true,
		moduleDependencies = {
			"evolvingObject",
			"gameObject"
		},
		loadFunction = "generateEvolvingObject"
	},

	material = {
		configSource = objectDB.materialConfigs,
		configPath = "/hammerstone/materials/",
		moduleDependencies = {
			"material"
		},
		loadFunction = "generateMaterialDefinition"
	},

	resource = {
		configSource = objectDB.objectConfigs,
		moduleDependencies = {
			"typeMaps",
			"resource"
		},
		loadFunction = "generateResourceDefinition"
	},

	gameObject = {
		configSource = objectDB.objectConfigs,
		configPath = "/hammerstone/objects/",
		waitingForStart = true,
		moduleDependencies = {
			"resource",
			"gameObject"
		},
		loadFunction = "generateGameObject"
	},

	recipe = {
		configSource = objectDB.recipeConfigs,
		configPath = "/hammerstone/recipes/",
		disabled = true,
		waitingForStart = true,
		moduleDependencies = {
			"gameObject",
			"constructable",
			"craftable",
			"skill",
			"craftAreaGroup",
			"action",
			"actionSequence",
			"tool",
			"resource"
		},
		loadFunction = "generateRecipeDefinition"
	},

	skill = {
		configSource = objectDB.skillConfigs,
		configPath = "/hammerstone/skills/",
		disabled = true,
		moduleDependencies = {
			"skill"
		},
		loadFunction = "generateSkillDefinition"
	}
}


local function newModuleAdded(modules)
	objectManager:tryLoadObjectDefinitions()
end

moduleManager:bind(newModuleAdded)

-- Initialize the full Data Driven API (DDAPI).
function objectManager:init()
	if utils:runOnceGuard("ddapi") then return end

	log:schema("ddapi", os.date())
	log:schema("ddapi", "\nInitializing DDAPI...")

	-- Load configs from FS
	configLoader:loadConfigs(objectLoader)
end


local function canLoadObjectType(objectName, objectData)
	-- Wait for configs to be loaded from the FS
	if configLoader.isInitialized == false then
		return false
	end

	-- Some routes wait for custom start logic. Don't start these until triggered!
	if objectData.waitingForStart == true then
		return false
	end
	
	-- Don't enable disabled modules
	if objectData.disabled then
		return false
	end

	-- Don't double-load objects
	if objectData.loaded == true then
		return false
	end

	-- Don't load until all dependencies are satisfied.
	for i, moduleDependency in pairs(objectData.moduleDependencies) do
		if moduleManager.modules[moduleDependency] == nil then
			return false
		end
	end

	-- If checks pass, then we can load the object
	objectData.loaded = true
	return true
end

--- Marks an object type as ready to load. 
-- @param configName the name of the config which is being marked as ready to load
function objectManager:markObjectAsReadyToLoad(configName)
	log:schema("ddapi", "Object is now ready to start loading: " .. configName)
	objectLoader[configName].waitingForStart = false
	objectManager:tryLoadObjectDefinitions() -- Re-trigger start logic, in case no more modules will be loaded.
end

--- Attempts to load object definitions from the objectLoader
function objectManager:tryLoadObjectDefinitions()
	for key, value in pairs(objectLoader) do
		if canLoadObjectType(key, value) then
			objectManager:loadObjectDefinition(key, value)
		end
	end
end

-- Loads a single object
function objectManager:loadObjectDefinition(objectName, objectData)
	log:schema("ddapi", "\nGenerating " .. objectName .. " definitions:")

	local configs = objectData.configSource
	if configs ~= nil and #configs ~= 0 then
		for i, config in ipairs(configs) do
			if config then
				objectManager[objectData.loadFunction](self, config) --Wtf oh my god
			else
				log:schema("ddapi", "WARNING: Attempting to generate nil " .. objectName)
			end
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

---------------------------------------------------------------------------------
-- Resource
---------------------------------------------------------------------------------

function objectManager:generateResourceDefinition(config)
	-- Modules
	local typeMapsModule = moduleManager:get("typeMaps")
	local resourceModule = moduleManager:get("resource")

	-- Setup
	local objectDefinition = config["hammerstone:object_definition"]
	local description = objectDefinition["description"]
	local components = objectDefinition["components"]
	local identifier = description["identifier"]

	-- Resource links prevent a *new* resource from being generated.
	local resourceLinkComponent = components["hammerstone:resource_link"]
	if resourceLinkComponent ~= nil then
		log:schema("ddapi", "GameObject " .. identifier .. " linked to resource " .. resourceLinkComponent.identifier .. ". No unique resource created.")
		return
	end

	log:schema("ddapi", "  " .. identifier)

	local name = description["name"]
	local plural = description["plural"]

	local newResource = {
		key = identifier,
		name = name,
		plural = plural,
		displayGameObjectTypeIndex = typeMapsModule.types.gameObject[identifier],
	}

	-- Handle Food
	local foodComponent = components["hammerstone:food"]
	if foodComponent ~= nil then
		--if type() -- TODO
		newResource.foodValue = foodComponent.value
		newResource.foodPortionCount = foodComponent.portions

		-- TODO These should be implemented with a smarter default value check
		if foodComponent.food_poison_chance ~= nil then
			newResource.foodPoisoningChance = foodComponent.food_poison_chance
		end
		
		if foodComponent.default_disabled ~= nil then
			newResource.defaultToEatingDisabled = foodComponent.default_disabled
		end
	end

	-- TODO: Consider handling `isRawMeat` and `isCookedMeat` for purpose of tutorial integration.

	-- Handle Decorations
	local decorationComponent = components["hammerstone:decoration"]
	if decorationComponent ~= nil then
		newResource.disallowsDecorationPlacing = not decorationComponent["enabled"]
	end

	objectManager:registerObjectForStorage(identifier, components["hammerstone:storage_link"])
	resourceModule:addResource(identifier, newResource)
end

---------------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------------

--- Special helper function to generate the resource IDs that a storage should use, once they are available.
function objectManager:generateResourceForStorage(storageIdentifier)

	local newResource = {}

	local objectIdentifiers = objectManager.objectsForStorage[storageIdentifier]
	if objectIdentifiers ~= nil then
		for i, identifier in ipairs(objectIdentifiers) do
			table.insert(newResource, moduleManager:get("resource").types[identifier].index)
		end
	else
		log:schema("ddapi", "WARNING: Storage " .. storageIdentifier .. " is being generated with zero items. This is most likely a mistake.")
	end

	return newResource
end

function objectManager:generateStorageObject(config)
	-- Modules
	local storageModule = moduleManager:get("storage")
	local typeMapsModule = moduleManager:get("typeMaps")

	-- Load structured information
	local storageDefinition = config["hammerstone:storage_definition"]
	local description = storageDefinition["description"]
	local storageComponent = storageDefinition.components["hammerstone:storage"]
	local carryComponent = storageDefinition.components["hammerstone:carry"]

	local gameObjectTypeIndexMap = typeMapsModule.types.gameObject

	local identifier = utils:getField(description, "identifier")

	log:schema("ddapi", "  " .. identifier)

	-- Prep
	local random_rotation_weight = utils:getField(storageComponent, "random_rotation_weight", {
		default = 2.0
	})
	local rotation = utils:getVec3(storageComponent, "rotation", {
		default = vec3(0.0, 0.0, 0.0)
	})

	local carryCounts = utils:getTable(carryComponent, "carry_count", {
		default = {} -- Allow this field to be undefined, but don't use nil
	})
	
	local newStorage = {
		key = identifier,
		name = utils:getField(description, "name"),

		displayGameObjectTypeIndex = gameObjectTypeIndexMap[utils:getField(storageComponent, "preview_object")],
		
		-- TODO: This needs to be reworked to make sure that it's possible to reference vanilla resources here (?)
		resources = objectManager:generateResourceForStorage(identifier),

		storageBox = {
			size =  utils:getVec3(storageComponent, "size", {
				default = vec3(0.5, 0.5, 0.5)
			}),
			
			-- TODO consider giving more control here
			rotationFunction = function(uniqueID, seed)
				local randomValue = rng:valueForUniqueID(uniqueID, seed)
				local rot = mat3Rotate(mat3Identity, randomValue * random_rotation_weight, rotation)
				return rot
			end,

			dontRotateToFitBelowSurface = utils:getField(storageComponent, "rotate_to_fit_below_surface", {
				default = true,
				type = "boolean"
			}),
			
			placeObjectOffset = mj:mToP(utils:getVec3(storageComponent, "offset", {
				default = vec3(0.0, 0.0, 0.0)
			}))
		},

		maxCarryCount = utils:getField(carryCounts, "normal", {default=1}),
		maxCarryCountLimitedAbility = utils:getField(carryCounts, "limited_ability", {default=1}),
		maxCarryCountForRunning = utils:getField(carryCounts, "running", {default=1}),

		carryStackType = storageModule.stackTypes[utils:getField(carryComponent, "stack_type", {default="standard"})],
		carryType = storageModule.carryTypes[utils:getField(carryComponent, "carry_type", {default="standard"})],

		carryOffset = utils:getVec3(carryComponent, "offset", {
			default = vec3(0.0, 0.0, 0.0)
		}),

		carryRotation = mat3Rotate(mat3Identity,
			utils:getField(carryComponent, "rotation_constant", { default = 1}),
			utils:getVec3(carryComponent, "rotation", { default = vec3(0.0, 0.0, 0.0)})
		),
	}

	storageModule:addStorage(identifier, newStorage)
end

---------------------------------------------------------------------------------
-- Evolving Objects
---------------------------------------------------------------------------------

--- Generates evolving object definitions. For example an orange rotting into a rotten orange.
function objectManager:generateEvolvingObject(config)
	-- Modules
	local evolvingObjectModule = moduleManager:get("evolvingObject")
	local gameObjectModule =  moduleManager:get("gameObject")

	-- Setup
	local object_definition = config["hammerstone:object_definition"]
	local evolvingObjectComponent = object_definition.components["hammerstone:evolving_object"]
	local identifier = object_definition.description.identifier
	
	-- If the component doesn't exist, then simply don't register an evolving object.
	if evolvingObjectComponent == nil then
		return -- This is allowed	
	else
		log:schema("ddapi", "  " .. identifier)
	end

	-- TODO: Make this smart, and can handle day length OR year length.
	-- It claims it reads it as lua (schema), but it actually just multiplies it by days.
	local newEvolvingObject = {
		minTime = evolvingObjectModule.dayLength * evolvingObjectComponent.min_time,
		categoryIndex = evolvingObjectModule.categories[evolvingObjectComponent.category].index,
	}

	if evolvingObjectComponent.transform_to ~= nil then
		local function generateTransformToTable(transform_to)
			local newResource = {}
			for i, identifier in ipairs(transform_to) do
				table.insert(newResource, gameObjectModule.types[identifier].index)
			end
			return newResource
		end

		newEvolvingObject.toTypes = generateTransformToTable(evolvingObjectComponent.transform_to)
	end

	evolvingObjectModule:addEvolvingObject(identifier, newEvolvingObject)
end

--- Registers an object into a storage.
-- @param identifier - The identifier of the object. e.g., hs:cake
-- @param componentData - The inner-table data for `hammerstone:storage`
function objectManager:registerObjectForStorage(identifier, componentData)

	if componentData == nil then
		return
	end

	-- Initialize this storage container, if this is the first item we're adding.
	local storageIdentifier = componentData.identifier
	if objectManager.objectsForStorage[storageIdentifier] == nil then
		objectManager.objectsForStorage[storageIdentifier] = {}
	end

	-- Insert the object identifier for this storage container
	table.insert(objectManager.objectsForStorage[storageIdentifier], identifier)
end

---------------------------------------------------------------------------------
-- Game Object
---------------------------------------------------------------------------------

function objectManager:generateGameObject(config)
	-- Modules
	local gameObjectModule = moduleManager:get("gameObject")
	local resourceModule = moduleManager:get("resource")

	-- Setup
	local object_definition = config["hammerstone:object_definition"]
	local description = object_definition["description"]
	local components = object_definition["components"]
	local objectComponent = components["hammerstone:object"]
	local identifier = description["identifier"]
	log:schema("ddapi", "  " .. identifier)

	local name = description["name"]
	local plural = description["plural"]
	local scale = objectComponent["scale"]
	local model = objectComponent["model"]
	local physics = objectComponent["physics"]
	local marker_positions = objectComponent["marker_positions"]
	
	-- Allow resource linking
	local resourceIdentifier = identifier
	local resourceLinkComponent = components["hammerstone:resource_link"]
	if resourceLinkComponent ~= nil then
		resourceIdentifier = resourceLinkComponent["identifier"]
	end

	-- If resource link doesn't exist, don't crash the game
	local resourceIndex = utils:getTypeIndex(resourceModule.types, resourceIdentifier, "Resource")
	if resourceIndex == nil then return end

	-- TODO: toolUsages
	-- TODO: selectionGroupTypeIndexes
	-- TODO: Implement eatByProducts

	-- TODO: These ones are probably for a new component related to world placement.
	-- allowsAnyInitialRotation
	-- randomMaxScale = 1.5,
	-- randomShiftDownMin = -1.0,
	-- randomShiftUpMax = 0.5,
	local newObject = {
		name = name,
		plural = plural,
		modelName = model,
		scale = scale,
		hasPhysics = physics,
		resourceTypeIndex = resourceIndex,

		-- TODO: Implement marker positions
		markerPositions = {
			{
				worldOffset = vec3(mj:mToP(0.0), mj:mToP(0.3), mj:mToP(0.0))
			}
		}
	}

	-- Actually register the game object
	gameObjectModule:addGameObject(identifier, newObject)
end

---------------------------------------------------------------------------------
-- Craftable
---------------------------------------------------------------------------------


function objectManager:generateRecipeDefinition(config)
	-- Modules
	local gameObjectModule = moduleManager:get("gameObject")
	local constructableModule = moduleManager:get("constructable")
	local craftableModule = moduleManager:get("craftable")
	local skillModule = moduleManager:get("skill")
	local craftAreaGroupModule = moduleManager:get("craftAreaGroup")
	local actionModule = moduleManager:get("action")
	local actionSequenceModule = moduleManager:get("actionSequence")
	local toolModule = moduleManager:get("tool")
	local resourceModule = moduleManager:get("resource")

	-- Definition
	local objectDefinition = config["hammerstone:recipe_definition"]
	local description = objectDefinition["description"]
	local identifier = description["identifier"]
	local components = objectDefinition["components"]

	-- Components
	local recipeComponent = components["hammerstone:recipe"]
	local requirementsComponent = components["hammerstone:requirements"]
	local outputComponent = components["hammerstone:output"]
	local buildSequenceComponent = components["hammerstone:build_sequence"]

	log:schema("ddapi", "  " .. identifier)

	local data = {

		-- Description
		identifier = utils:getField(description, "identifier", {
			notInTypeTable = craftableModule.types
		}),
		name = utils:getField(description, "name"),
		plural = utils:getField(description, "plural"),
		summary = utils:getField(description, "summary"),


		-- Recipe Component
		iconGameObjectType = utils:getField(recipeComponent, "preview_object", {
			inTypeTable = moduleManager:get("gameObject").types
		}),
		classification = utils:getField(recipeComponent, "classification", {
			inTypeTable = constructableModule.classifications,
			default = "craft"
		}),
		isFoodPreperation = utils:getField(recipeComponent, "is_food_prep", {
			type = "boolean",
			default = false
		}),

		
		-- TODO: If the component doesn't exist, then set `hasNoOutput` instead.
		outputObjectInfo = {
			outputArraysByResourceObjectType = utils:getTable(outputComponent, "output_by_object", {
				with = function(tbl)
					local result = {}
					for _, value in pairs(tbl) do -- Loop through all output objects
						
						-- Return if input isn't a valid gameObject
						if utils:getTypeIndex(gameObjectModule.types, value.input, "Game Object") == nil then return end

						-- Get the input's resource index
						local index = gameObjectModule.types[value.input].index

						-- Convert from schema format to vanilla format
						-- If the predicate returns nil for any element, map returns nil
						-- In this case, log an error and return if any output item does not exist in gameObject.types
						result[index] = utils:map(value.output, function(e)
							return utils:getTypeIndex(gameObjectModule.types, e, "Game Object")
						end)
					end
					return result
				end
			}),
		},


		-- Requirements Component
		skills = utils:getTable(requirementsComponent, "skills", {
			inTypeTable = skillModule.types,
			with = function(tbl)
				if #tbl > 0 then
					return {
						required = skillModule.types[tbl[1] ].index
					}
				end
			end
		}),
		disabledUntilAdditionalSkillTypeDiscovered = utils:getTable(requirementsComponent, "skills", {
			inTypeTable = skillModule.types,
			with = function(tbl)
				if #tbl > 1 then
					return skillModule.types[tbl[2] ].index
				end
			end
		}),
		requiredCraftAreaGroups = utils:getTable(requirementsComponent, "craft_area_groups", {
			map = function(e)
				return utils:getTypeIndex(craftAreaGroupModule.types, e, "Craft Area Group")
			end
		}),
		requiredTools = utils:getTable(requirementsComponent, "tools", {
			map = function(e)
				return utils:getTypeIndex(toolModule.types, e, "Tool")
			end
		}),


		-- Build Sequence Component
		inProgressBuildModel = utils:getField(buildSequenceComponent, "build_sequence_model"),
		buildSequence = utils:getTable(buildSequenceComponent, "build_sequence", {
			with = function(tbl)
				if not utils:isEmpty(tbl.steps) then
					-- If steps exist, we create a custom build sequence instead a standard one
					log:logNotImplemented("Custom Build Sequence") -- TODO: Implement steps
				else
					-- Cancel if action field doesn't exist
					if tbl.action == nil then
						return log:schema("ddapi", "    Missing Action Sequence")
					end

					-- Get the action sequence
					local sequence = utils:getTypeIndex(actionSequenceModule.types, tbl.action, "Action Sequence")
					if sequence ~= nil then

						-- Cancel if a tool is stated but doesn't exist
						if tbl.tool ~= nil and #tbl.tool > 0 and utils:getTypeIndex(toolModule.types, tbl.tool, "Tool") == nil then
							return
						end

						-- Return the standard build sequence constructor
						return craftableModule:createStandardBuildSequence(sequence, tbl.tool)
					end
				end
			end
		}),
		requiredResources = utils:getTable(buildSequenceComponent, "craft_sequence", {
			-- Runs for each item and replaces item with return result
			map = function(e)

				-- Get the resource
				local res = utils:getTypeIndex(resourceModule.types, e.resource, "Resource")
				if (res == nil) then return end -- Cancel if resource does not exist

				-- Get the count
				local count = utils:getField(e, "count", {default=1, type="number"})

				if e.action ~= nil then

					-- Return if action is invalid
					local actionType = utils:getTypeIndex(actionModule.types, e.action.action_type, "Action")
					if (actionType == nil) then return end

					-- Return if duration is invalid
					local duration = e.action.duration
					if (not utils:isType(duration, "number")) then
						return log:schema("ddapi", "    Duration for " .. e.action.action_type .. " is not a number")
					end

					-- Return if duration without skill is invalid
					local durationWithoutSkill = e.action.duration_without_skill or duration
					if (not utils:isType(durationWithoutSkill, "number")) then
						return log:schema("ddapi", "    Duration without skill for " .. e.action.action_type .. " is not a number")
					end

					return {
						type = res,
						count = count,
						afterAction = {
							actionTypeIndex = actionType,
							duration = duration,
							durationWithoutSkill = durationWithoutSkill,
						}
					}
				end
				return {
					type = res,
					count = count,
				}
			end
		})
	}

	if data ~= nil then
		-- Add recipe
		craftableModule:addCraftable(identifier, data)

		-- Add items in crafting panels
		for _, group in ipairs(data.requiredCraftAreaGroups) do
			local key = gameObjectModule.typeIndexMap[craftAreaGroupModule.types[group].key]
			if objectManager.inspectCraftPanelData[key] == nil then
				objectManager.inspectCraftPanelData[key] = {}
			end
			table.insert(objectManager.inspectCraftPanelData[key], constructableModule.types[identifier].index)
		end
	end
end

---------------------------------------------------------------------------------
-- Material
---------------------------------------------------------------------------------

function objectManager:generateMaterialDefinition(config)
	-- Modules
	local materialModule = moduleManager:get("material")

	-- Setup
	local materialDefinition = config["hammerstone:material_definition"]
	local materials = materialDefinition["materials"]

	for _, mat in pairs(materials) do

		log:schema("ddapi", "  " .. mat["identifier"])

		local required = {
			identifier = true,
			color = true,
			roughness = true,
			metal = false,
		}

		local data = utils:compile(required, {

			identifier = utils:getField(mat, "identifier", {
				notInTypeTable = moduleManager:get("material").types
			}),

			color = utils:getVec3(mat, "color"),
			
			roughness = utils:getField(mat, "roughness", {
				type = "number"
			}),

			metal = utils:getField(mat, "metal", {
				type = "number"
			})
		})

		if data ~= nil then
			materialModule:addMaterial(data.identifier, data.color, data.roughness, data.metal)
		end
	end
end

---------------------------------------------------------------------------------
-- Skill
---------------------------------------------------------------------------------

--- Generates skill definitions based on the loaded config, and registers them.

function objectManager:generateSkillDefinition(config)
	-- Modules
	local skillModule = moduleManager:get("skill")

	-- Setup
	local skillDefinition = config["hammerstone:skill_definition"]
	local skills = skillDefinition["skills"]

	for _, s in pairs(skills) do

		local desc = s["description"]
		local skil = s["skill"]

		log:schema("ddapi", "  " .. desc["identifier"])

		local required = {
			identifier = true,
			name = true,
			description = true,
			icon = true,

			row = true,
			column = true,
			requiredSkillTypes = false,
			startLearned = false,
			partialCapacityWithLimitedGeneralAbility = false,
		}

		local data = utils:compile(required, {

			identifier = utils:getField(desc, "identifier", {
				notInTypeTable = skillModule.types
			}),
			name = utils:getField(desc, "name"),
			description = utils:getField(desc, "description"),
			icon = utils:getField(desc, "icon"),

			row = utils:getField(skil, "row", {
				type = "number"
			}),
			column = utils:getField(skil, "column", {
				type = "number"
			}),
			requiredSkillTypes = utils:getTable(skil, "requiredSkills", {
				-- Make sure each skill exists and transform skill name to index
				map = function(e) return utils:getTypeIndex(skillModule.types, e, "Skill") end
			}),
			startLearned = utils:getField(skil, "startLearned", {
				type = "boolean"
			}),
			partialCapacityWithLimitedGeneralAbility = utils:getField(skil, "impactedByLimitedGeneralAbility", {
				type = "boolean"
			}),
		})

		if data ~= nil then
			skillModule:addSkill(data.identifier, data)
		end
	end
end

return objectManager