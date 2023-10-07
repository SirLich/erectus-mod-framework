--- Hammerstone: activeOrderAI.lua
--- @author Witchy

-- Hammerstone
local shadow = mjrequire "hammerstone/utils/shadow"
local moduleManager = mjrequire "hammerstone/state/moduleManager"

local activeOrderAI = {}

local context = nil

function activeOrderAI:preload(parent)
	moduleManager:addModule("activeOrderAI", parent)
end

function activeOrderAI:init(super, serverSapienAI_, serverSapien_, serverGOM_, serverWorld_, findOrderAI_)
	super(self, serverSapienAI_, serverSapien_, serverGOM_, serverWorld_, findOrderAI_)

	context = {
		serverSapienAI = serverSapienAI_, 
		serverSapien = serverSapien_, 
		serverGOM = serverGOM_, 
		serverWorld = serverWorld_,
		findOrderAI = findOrderAI_
	}
end

function activeOrderAI:getContext()
	return context
end

return shadow:shadow(activeOrderAI)