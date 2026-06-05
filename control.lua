-- control.lua for Vehicle Control Center mod

-- Load modules
local control_center = require("scripts.control_center")

local function log_debug(message)
    log("[Vehicle Control Center] " .. message)
end

-- Check if Neural Spider Control mod is present
local neural_mod_present = script.active_mods["neural-spider-control"] ~= nil

local CONTEXT_BUTTON_ACTION = "vcc_context_button_click"
local VEHICLE_CONTEXT_TOOLBAR_NAME = "vcc_vehicle_context_toolbar"
local CONTEXT_TOOLBAR_BUTTON_FRAME_NAME = "button_frame"
local CONTEXT_TOOLBAR_BUTTON_FLOW_NAME = "button_flow"
local PLAYER_CONTEXT_TOOLBAR_NAME = "vcc_player_context_toolbar"
local provider_registry = {}

local function provider_key(mod_id, button_id)
    return tostring(mod_id) .. "\x1f" .. tostring(button_id)
end

local function sanitize_key(key)
    return key:gsub("[^%w_]", "_")
end

--- Old NSC rows used vanilla sprites that no longer exist in 2.0. Remap only
--- those to VCC sprites from data.lua (vcc-map, vcc-whistle). Everything else
--- is passed through unchanged (NSC already registers vcc-* where needed).
local function resolved_context_sprite(sprite)
    if type(sprite) ~= "string" or sprite == "" then
        return "utility/questionmark"
    end
    if sprite == "utility/open_map" or sprite == "utility/gps_map_icon" then
        return "vcc-map"
    end
    if sprite == "utility/entity_info" then
        return "vcc-whistle"
    end
    return sprite
end

local function serialize_vehicle(vehicle)
    if not vehicle or not vehicle.valid then
        return nil
    end
    return {
        unit_number = vehicle.unit_number,
        surface_index = vehicle.surface.index,
        vehicle_type = vehicle.type
    }
end

--- player.opened may be LuaEntity, LuaGuiElement, LuaEquipmentGrid, etc.
local function opened_is_vehicle_entity(opened)
    return opened and opened.valid and opened.object_name == "LuaEntity"
        and (opened.type == "spider-vehicle" or opened.type == "car")
end

local function ensure_provider_storage()
    storage.vcc = storage.vcc or {}
    storage.vcc.context_button_registry = storage.vcc.context_button_registry or {}
end

local function restore_provider_registry_from_storage()
    provider_registry = {}
    if not storage or not storage.vcc or type(storage.vcc.context_button_registry) ~= "table" then
        return
    end
    for key, cfg in pairs(storage.vcc.context_button_registry) do
        provider_registry[key] = cfg
    end
end

local function persist_provider_entry(entry)
    ensure_provider_storage()
    storage.vcc.context_button_registry[entry.key] = {
        mod_id = entry.mod_id,
        button_id = entry.button_id,
        key = entry.key,
        context = entry.context,
        vehicle_types = entry.vehicle_types,
        priority = entry.priority,
        sprite = entry.sprite,
        tooltip = entry.tooltip,
        style = entry.style,
        show_when_remote_no_selection = entry.show_when_remote_no_selection,
        callback_interface = entry.callback_interface,
        condition_action = entry.condition_action,
        tags_action = entry.tags_action,
        click_action = entry.click_action
    }
end

local function register_context_button(mod_id, button_id, config, persist)
    if type(mod_id) ~= "string" or type(button_id) ~= "string" or type(config) ~= "table" then
        return false
    end

    local key = provider_key(mod_id, button_id)
    local prev = provider_registry[key] or {}
    local vehicle_types = config.vehicle_types or prev.vehicle_types or {}
    local entry = {
        mod_id = mod_id,
        button_id = button_id,
        key = key,
        context = config.context or prev.context or "vehicle_relative",
        vehicle_types = vehicle_types,
        priority = config.priority or prev.priority or 100,
        sprite = config.sprite or prev.sprite or "utility/questionmark",
        tooltip = config.tooltip or prev.tooltip,
        style = config.style or prev.style or "slot_sized_button",
        show_when_remote_no_selection = config.show_when_remote_no_selection == true or prev.show_when_remote_no_selection == true,
        callback_interface = config.callback_interface or prev.callback_interface or mod_id,
        condition_action = config.condition_action or prev.condition_action,
        tags_action = config.tags_action or prev.tags_action,
        click_action = config.click_action or prev.click_action
    }

    provider_registry[key] = entry
    if persist ~= false then
        persist_provider_entry(entry)
    end
    return true
end

local function unregister_context_button(mod_id, button_id)
    if type(mod_id) ~= "string" or type(button_id) ~= "string" then
        return false
    end
    local key = provider_key(mod_id, button_id)
    provider_registry[key] = nil
    ensure_provider_storage()
    storage.vcc.context_button_registry[key] = nil
    return true
end

local function register_builtin_context_buttons(persist)
    register_context_button("vehicle-control-center", "get_remote_vehicle", {
        context = "vehicle_relative",
        vehicle_types = {"spider-vehicle"},
        priority = 8,
        sprite = "item/spidertron-remote",
        tooltip = {"vcc.get-remote"},
        callback_interface = "vehicle-control-center",
        click_action = "vcc_click_get_remote"
    }, persist)
end

local function collect_selected_vehicles(player)
    local raw = player and player.spidertron_remote_selection
    local out = {}
    if not raw then
        return out
    end
    for _, vehicle in ipairs(raw) do
        if vehicle and vehicle.valid and (vehicle.type == "spider-vehicle" or vehicle.type == "car") then
            table.insert(out, vehicle)
        end
    end
    return out
end

local function player_holding_spidertron_remote(player)
    if not player or not player.valid then
        return false
    end
    local stack = player.cursor_stack
    if not stack or not stack.valid_for_read then
        return false
    end
    if stack.name == "spidertron-remote" then
        return true
    end
    return stack.prototype and stack.prototype.type == "spidertron-remote"
end

local function make_remote_selection_signature(player)
    if not player_holding_spidertron_remote(player) then
        return "no-remote"
    end

    local selected = collect_selected_vehicles(player)
    if #selected == 0 then
        return "remote:none"
    end

    local parts = {}
    for _, vehicle in ipairs(selected) do
        table.insert(parts, tostring(vehicle.surface.index) .. ":" .. tostring(vehicle.unit_number))
    end
    table.sort(parts)
    return "remote:" .. table.concat(parts, "|")
end

local function call_provider_action(entry, action_name, payload)
    if not entry or not action_name then
        return nil, false
    end
    local interface_name = entry.callback_interface or entry.mod_id
    if not remote.interfaces[interface_name] or not remote.interfaces[interface_name][action_name] then
        return nil, false
    end
    local ok, result = pcall(remote.call, interface_name, action_name, payload)
    if not ok then
        log_debug("Provider callback failed: " .. interface_name .. "." .. action_name .. " -> " .. tostring(result))
        return nil, false
    end
    return result, true
end

local function get_spider_relative_gui_type()
    local d = defines.relative_gui_type
    return d.spider_vehicle_gui or d.spidertron_gui
end

local function build_vehicle_anchor(vehicle)
    if not vehicle or not vehicle.valid then
        return nil
    end
    if vehicle.type == "spider-vehicle" then
        local gui_type = get_spider_relative_gui_type()
        if not gui_type then
            return nil
        end
        return {gui = gui_type, position = defines.relative_gui_position.right}
    end
    if vehicle.type == "car" then
        return {gui = defines.relative_gui_type.car_gui, position = defines.relative_gui_position.right}
    end
    return nil
end

local function destroy_vehicle_context_toolbar(player)
    if not player or not player.valid then
        return
    end
    local root = player.gui.relative[VEHICLE_CONTEXT_TOOLBAR_NAME]
    if root and root.valid then
        root.destroy()
    end
end

local function destroy_player_context_toolbar(player)
    if not player or not player.valid then
        return
    end
    local root = player.gui.left[PLAYER_CONTEXT_TOOLBAR_NAME]
    if root and root.valid then
        root.destroy()
    end
end

-- Initialize mod

-- Scan for vehicles on all surfaces and cache the results
function scan_for_vehicles()
    log_debug("Scanning for vehicles")
    
    storage.vcc.vehicles = {}
    
    for _, surface in pairs(game.surfaces) do
        storage.vcc.vehicles[surface.index] = {
            cars = {},
            locomotives = {},
            spidertrons = {}
        }
        
        -- Find spider-vehicles
        local spidertrons = surface.find_entities_filtered{type = "spider-vehicle"}
        for _, spidertron in pairs(spidertrons) do
            if spidertron.valid then
                table.insert(storage.vcc.vehicles[surface.index].spidertrons, {
                    entity = spidertron,
                    unit_number = spidertron.unit_number,
                    position = spidertron.position,
                    occupied = spidertron.get_driver() ~= nil,
                    name = spidertron.name
                })
            end
        end
        
        -- Find cars
        local cars = surface.find_entities_filtered{type = "car"}
        for _, car in pairs(cars) do
            if car.valid and car.prototype.allow_passengers then
                table.insert(storage.vcc.vehicles[surface.index].cars, {
                    entity = car,
                    unit_number = car.unit_number,
                    position = car.position,
                    occupied = car.get_driver() ~= nil,
                    name = car.name
                })
            end
        end
        
        -- Find locomotives
        local locomotives = surface.find_entities_filtered{type = "locomotive"}
        for _, locomotive in pairs(locomotives) do
            if locomotive.valid then
                table.insert(storage.vcc.vehicles[surface.index].locomotives, {
                    entity = locomotive,
                    unit_number = locomotive.unit_number,
                    position = locomotive.position,
                    occupied = locomotive.get_driver() ~= nil,
                    name = locomotive.name
                })
            end
        end
    end
    
    log_debug("Vehicle scan complete")
end

local function init()
    log_debug("Initializing Vehicle Control Center mod")
    
    if not storage then storage = {} end
    
    -- Initialize storage tables
    storage.vcc = storage.vcc or {}
    storage.vcc.players = storage.vcc.players or {}
    storage.vcc.vehicles = storage.vcc.vehicles or {}
    storage.vcc.neural_mod_present = neural_mod_present
    storage.vcc.last_vehicle_type = storage.vcc.last_vehicle_type or {}
    storage.vcc.vehicle_filters = storage.vcc.vehicle_filters or {}
    storage.vcc.context_button_registry = storage.vcc.context_button_registry or {}
    storage.vcc.remote_toolbar_state = storage.vcc.remote_toolbar_state or {}
    restore_provider_registry_from_storage()
    register_builtin_context_buttons()
    
    log_debug("Neural Spider Control mod " .. (neural_mod_present and "is" or "is not") .. " present")
    
    -- Initialize the control center
    if control_center.initialize then
        control_center.initialize()
    end
    
    log_debug("Initialization complete")
end

-- Then register the on_init event
script.on_init(function()
    init()
    scan_for_vehicles()
end)

-- Find a vehicle by unit number on a specific surface
function find_vehicle_by_unit_number(unit_number, surface_index)
    local surface = game.surfaces[surface_index]
    if not surface then return nil end
    
    -- First check spidertrons
    for _, entity in pairs(surface.find_entities_filtered{type = "spider-vehicle"}) do
        if entity.unit_number == unit_number then
            return entity
        end
    end
    
    -- Then check cars
    for _, entity in pairs(surface.find_entities_filtered{type = "car"}) do
        if entity.unit_number == unit_number then
            return entity
        end
    end
    
    -- Finally check locomotives
    for _, entity in pairs(surface.find_entities_filtered{type = "locomotive"}) do
        if entity.unit_number == unit_number then
            return entity
        end
    end
    
    return nil
end

-- Function to handle neural connect button clicks
local function connect_to_vehicle(player, unit_number, surface_index)
    log_debug("Attempting to connect to vehicle #" .. unit_number)
    
    -- Find the vehicle
    local surface = game.surfaces[surface_index]
    if not surface then 
        player.print("Surface not found")
        return 
    end
    
    local vehicle = nil
    for _, entity in pairs(surface.find_entities_filtered{type = {"spider-vehicle", "car", "locomotive"}}) do
        if entity.unit_number == unit_number then
            vehicle = entity
            break
        end
    end
    
    if not vehicle or not vehicle.valid then
        player.print("Vehicle not found")
        return
    end
    
    -- Close the GUI
    if player.gui.screen.vehicle_control_center then
        control_center.close_gui(player)
    end
    
    -- Use the remote interface to connect
    if remote.interfaces["neural-spider-control"] and 
       remote.interfaces["neural-spider-control"]["connect_to_vehicle"] then
        remote.call("neural-spider-control", "connect_to_vehicle", {
            player_index = player.index,
            vehicle = vehicle
        })
    else
        player.print("Failed to connect: Neural Spider Control mod may be missing or not properly loaded.")
        log_debug("Neural Spider Control remote interface not found")
    end
end

local function sort_provider_entries(entries)
    table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.key < b.key
    end)
end

local function provider_supports_vehicle(entry, vehicle_type)
    if not entry.vehicle_types or #entry.vehicle_types == 0 then
        return true
    end
    for _, allowed in ipairs(entry.vehicle_types) do
        if allowed == vehicle_type then
            return true
        end
    end
    return false
end

local function build_provider_payload(player, context_name, context_vehicle, selected_vehicles)
    local serialized_selected = {}
    for _, selected in ipairs(selected_vehicles) do
        local ref = serialize_vehicle(selected)
        if ref then
            table.insert(serialized_selected, ref)
        end
    end
    return {
        player_index = player.index,
        context = context_name,
        vehicle = serialize_vehicle(context_vehicle),
        selected_vehicles = serialized_selected
    }
end

local function render_vehicle_context_toolbar(player, vehicle)
    if not player or not player.valid then
        return
    end
    if not vehicle or not vehicle.valid or (vehicle.type ~= "spider-vehicle" and vehicle.type ~= "car") then
        destroy_vehicle_context_toolbar(player)
        return
    end

    local anchor = build_vehicle_anchor(vehicle)
    if not anchor then
        destroy_vehicle_context_toolbar(player)
        return
    end

    local root = player.gui.relative[VEHICLE_CONTEXT_TOOLBAR_NAME]
    if root and root.valid then
        root.destroy()
    end

    root = player.gui.relative.add{
        type = "frame",
        name = VEHICLE_CONTEXT_TOOLBAR_NAME,
        anchor = anchor,
        style = "frame"
    }
    root.style.horizontally_stretchable = false
    root.style.vertically_stretchable = false
    root.style.top_padding = 6
    root.style.bottom_padding = 6
    root.style.left_padding = 6
    root.style.right_padding = 6

    local button_frame = root.add{
        type = "frame",
        name = CONTEXT_TOOLBAR_BUTTON_FRAME_NAME,
        direction = "vertical",
        style = "inside_shallow_frame"
    }
    button_frame.style.vertically_stretchable = false

    local flow = button_frame.add{
        type = "flow",
        name = CONTEXT_TOOLBAR_BUTTON_FLOW_NAME,
        direction = "vertical"
    }

    local selected_vehicles = collect_selected_vehicles(player)
    local payload = build_provider_payload(player, "vehicle_relative", vehicle, selected_vehicles)
    local visible_entries = {}
    for _, entry in pairs(provider_registry) do
        if entry.context == "vehicle_relative" and provider_supports_vehicle(entry, vehicle.type) then
            local visible = true
            if entry.condition_action then
                local result, ok = call_provider_action(entry, entry.condition_action, payload)
                visible = ok and result == true
            end
            if visible then
                table.insert(visible_entries, entry)
            end
        end
    end
    sort_provider_entries(visible_entries)

    for _, entry in ipairs(visible_entries) do
        local tags = {
            action = CONTEXT_BUTTON_ACTION,
            provider_key = entry.key,
            vehicle_unit_number = vehicle.unit_number,
            surface_index = vehicle.surface.index
        }
        if entry.tags_action then
            local generated_tags, ok = call_provider_action(entry, entry.tags_action, payload)
            if ok and type(generated_tags) == "table" then
                for k, v in pairs(generated_tags) do
                    tags[k] = v
                end
            end
        end

        local btn = flow.add{
            type = "sprite-button",
            name = "vcc_ctx_" .. sanitize_key(entry.key),
            sprite = resolved_context_sprite(entry.sprite or "utility/questionmark"),
            tooltip = entry.tooltip,
            style = entry.style or "slot_sized_button",
            tags = tags
        }
    end

    if #visible_entries == 0 then
        root.destroy()
    end
end

local function render_player_context_toolbar(player)
    if not player or not player.valid then
        return
    end

    local selected_vehicles = collect_selected_vehicles(player)
    local holding_remote = player_holding_spidertron_remote(player)
    local remote_no_selection = (#selected_vehicles == 0 and holding_remote)
    if #selected_vehicles == 0 and not holding_remote then
        destroy_player_context_toolbar(player)
        return
    end

    local payload = build_provider_payload(player, "player_left_toolbar", nil, selected_vehicles)
    local visible_entries = {}
    for _, entry in pairs(provider_registry) do
        if entry.context == "player_left_toolbar" then
            local allowed = (#selected_vehicles > 0)
            if remote_no_selection then
                allowed = entry.show_when_remote_no_selection == true
            elseif #selected_vehicles > 0 and entry.vehicle_types and #entry.vehicle_types > 0 then
                allowed = false
                for _, selected in ipairs(selected_vehicles) do
                    if provider_supports_vehicle(entry, selected.type) then
                        allowed = true
                        break
                    end
                end
            end

            if allowed then
                local visible = true
                if entry.condition_action then
                    local result, ok = call_provider_action(entry, entry.condition_action, payload)
                    visible = ok and result == true
                end
                if visible then
                    table.insert(visible_entries, entry)
                end
            end
        end
    end
    sort_provider_entries(visible_entries)

    if #visible_entries == 0 then
        destroy_player_context_toolbar(player)
        return
    end

    local root = player.gui.left[PLAYER_CONTEXT_TOOLBAR_NAME]
    if root and root.valid then
        root.destroy()
    end

    root = player.gui.left.add{
        type = "frame",
        name = PLAYER_CONTEXT_TOOLBAR_NAME,
        style = "frame"
    }
    root.style.horizontally_stretchable = false
    root.style.vertically_stretchable = false
    root.style.top_padding = 6
    root.style.bottom_padding = 6
    root.style.left_padding = 6
    root.style.right_padding = 6

    local button_frame = root.add{
        type = "frame",
        name = CONTEXT_TOOLBAR_BUTTON_FRAME_NAME,
        direction = "vertical",
        style = "inside_shallow_frame"
    }
    button_frame.style.vertically_stretchable = false

    local flow = button_frame.add{
        type = "flow",
        name = CONTEXT_TOOLBAR_BUTTON_FLOW_NAME,
        direction = "vertical"
    }

    for _, entry in ipairs(visible_entries) do
        local tags = {
            action = CONTEXT_BUTTON_ACTION,
            provider_key = entry.key
        }
        if entry.tags_action then
            local generated_tags, ok = call_provider_action(entry, entry.tags_action, payload)
            if ok and type(generated_tags) == "table" then
                for k, v in pairs(generated_tags) do
                    tags[k] = v
                end
            end
        end

        local btn = flow.add{
            type = "sprite-button",
            name = "vcc_left_" .. sanitize_key(entry.key),
            sprite = resolved_context_sprite(entry.sprite or "utility/questionmark"),
            tooltip = entry.tooltip,
            style = entry.style or "slot_sized_button",
            tags = tags
        }
    end
end

local function refresh_context_toolbars_for_player(player)
    if not player or not player.valid then
        return
    end
    local opened = player.opened
    if opened_is_vehicle_entity(opened) then
        render_vehicle_context_toolbar(player, opened)
    else
        destroy_vehicle_context_toolbar(player)
    end
    render_player_context_toolbar(player)
end

local function dispatch_context_button_click(player, element)
    local tags = element.tags or {}
    local provider_key_name = tags.provider_key
    if not provider_key_name then
        return false
    end
    local entry = provider_registry[provider_key_name]
    if not entry or not entry.click_action then
        return false
    end

    local selected_vehicles = collect_selected_vehicles(player)
    local context_vehicle = nil
    if tags.vehicle_unit_number and tags.surface_index then
        context_vehicle = find_vehicle_by_unit_number(tags.vehicle_unit_number, tags.surface_index)
    end
    if not context_vehicle and opened_is_vehicle_entity(player.opened) then
        context_vehicle = player.opened
    end

    local payload = build_provider_payload(player, entry.context, context_vehicle, selected_vehicles)
    payload.button_tags = tags
    payload.element_name = element.name
    call_provider_action(entry, entry.click_action, payload)
    refresh_context_toolbars_for_player(player)
    return true
end

-- Event handlers

-- Handle new players
script.on_event(defines.events.on_player_created, function(event)
    local player = game.get_player(event.player_index)
end)

-- Handle configuration changes
script.on_configuration_changed(function(data)
    log_debug("Configuration changed")
    ensure_provider_storage()
    restore_provider_registry_from_storage()
    register_builtin_context_buttons()
end)

script.on_load(function()
    restore_provider_registry_from_storage()
    -- on_load must not modify storage; only refresh in-memory built-in entries.
    register_builtin_context_buttons(false)
end)

function update_vehicle_tracking()
    for player_index, player_data in pairs(storage.vcc.players) do
        local player = game.get_player(player_index)
        if not player or not player.valid then goto continue end
        
        -- Update view for vehicle following
        if player_data.following_vehicle and player.controller_type == defines.controllers.remote then
            -- Find the vehicle again
            local surface = game.surfaces[player_data.following_vehicle_surface]
            if not surface then goto continue end
            
            local vehicle = nil
            for _, entity in pairs(surface.find_entities_filtered{type = {"spider-vehicle", "car", "locomotive"}}) do
                if entity.unit_number == player_data.following_vehicle_id then
                    vehicle = entity
                    break
                end
            end
            
            -- If vehicle is valid, update player's view position
            if vehicle and vehicle.valid then
                player.set_controller({
                    type = defines.controllers.remote,
                    position = vehicle.position,
                    surface = vehicle.surface,
                    start_zoom = 0.5
                })
            else
                -- Vehicle no longer valid, stop following
                player_data.following_vehicle = false
                player_data.following_vehicle_id = nil
                player_data.following_vehicle_surface = nil
                
                -- Return to character control if player still in remote mode
                if player.controller_type == defines.controllers.remote then
                    player.set_controller({ type = defines.controllers.character })
                end
            end
        elseif player_data.following_vehicle and player.controller_type ~= defines.controllers.remote then
            -- Player exited remote view, stop following
            player_data.following_vehicle = false
            player_data.following_vehicle_id = nil
            player_data.following_vehicle_surface = nil
        end
        
        ::continue::
    end
end

-- Add handler for when player exits map view (needed for cleanup)
script.on_event(defines.events.on_player_changed_surface, function(event)
    local player = game.get_player(event.player_index)
    local player_data = storage.vcc.players[event.player_index]
    
    if player and player_data and player_data.following_vehicle then
        -- Stop following if player changed surface
        player_data.following_vehicle = false
        player_data.following_vehicle_id = nil
        player_data.following_vehicle_surface = nil
    end
end)

-- Handle GUI clicks
script.on_event(defines.events.on_gui_click, function(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    
    if not player or not element or not element.valid then return end
    
    -- Extract action from tags if present
    local action = element.tags and element.tags.action

    if action == CONTEXT_BUTTON_ACTION then
        if dispatch_context_button_click(player, element) then
            return
        end
    end
    
    -- Handle close buttons
    if element.name == "vcc_close_button" or element.name == "close_vehicle_control_center" then
        control_center.close_gui(player)
        return
    end
    
    -- Handle camera GUI close button
    if element.name == "close_vehicle_camera" then
        if player.gui.screen.vehicle_camera_frame then
            player.gui.screen.vehicle_camera_frame.destroy()
        end
        return
    end
    
    -- Handle pinned camera close button
    if action == "close_pinned_camera" then
        local unit_number = element.tags.unit_number
        local unit_number_str = tostring(unit_number)
        if player.gui.screen["vehicle_camera_" .. unit_number_str] then
            player.gui.screen["vehicle_camera_" .. unit_number_str].destroy()
        end
        local player_data = storage.vcc.players[player.index] or {}
        if player_data.pinned_cameras then
            player_data.pinned_cameras[unit_number] = nil
        end
        return
    end
    
    -- Handle pinned camera toggle
    if action == "toggle_pinned_camera" then
        local unit_number = element.tags.unit_number
        local frame = player.gui.screen.vehicle_pinned_camera_frame and player.gui.screen.vehicle_pinned_camera_frame[unit_number]
        if frame then
            local is_collapsed = frame.tags and frame.tags.is_collapsed
            frame.tags = {is_collapsed = not is_collapsed}
            frame.camera_content.visible = not is_collapsed
            frame.title_flow.toggle_button.sprite = is_collapsed and "utility/collapse" or "utility/expand"
            frame.title_flow.toggle_button.tooltip = is_collapsed and {"vcc.expand-camera"} or {"vcc.collapse-camera"}
        end
        return
    end
    
    -- Handle refresh button
    if element.name == "vcc_refresh_button" then
        scan_for_vehicles()
        local player_data = storage.vcc.players[player.index]
        local vehicle_type = player_data and storage.vcc.last_vehicle_type[player.index] or "all"
        control_center.create_gui(player, vehicle_type)
        return
    end
    
    -- Handle open vehicle camera
    if action == "open_vehicle_camera" then
        local unit_number = element.tags.unit_number
        local surface_index = element.tags.surface_index
        player.print("Vehicle icon clicked for vehicle #" .. unit_number)
        
        local vehicle = find_vehicle_by_unit_number(unit_number, surface_index)
        if not vehicle or not vehicle.valid then
            player.print("Vehicle not found or invalid")
            return
        end
        
        local success, error = pcall(control_center.create_pinned_camera_gui, player, {
            entity = vehicle,
            name = vehicle.name,
            position = vehicle.position,
            surface_index = surface_index
        }, nil)
        if not success then
            player.print("Failed to create pinned camera GUI: " .. tostring(error))
            return
        end
        
        local player_data = storage.vcc.players[player.index] or {}
        storage.vcc.players[player.index] = player_data
        if not player_data.pinned_cameras then
            player_data.pinned_cameras = {}
        end
        player_data.pinned_cameras[unit_number] = true
        return
    end

    if action == "close_pinned_camera" then
        local unit_number = element.tags.unit_number
        local unit_number_str = tostring(unit_number)
        player.print("Close button clicked for vehicle #" .. unit_number)
        
        local frame = player.gui.screen["vehicle_camera_" .. unit_number_str]
        if frame and frame.valid then
            frame.destroy()
            player.print("Pinned camera GUI closed for vehicle #" .. unit_number)
        else
            player.print("Pinned camera GUI not found for vehicle #" .. unit_number)
        end
        
        local player_data = storage.vcc.players[player.index] or {}
        if player_data.pinned_cameras then
            player_data.pinned_cameras[unit_number] = nil
        end
        return
    end
    
    -- Handle other actions from tags
    if action then
        if action == "surface_selector" then
            control_center.create_surface_dropdown(player)
            return
        elseif action == "select_surface" then
            local surface_index = element.tags.surface_index
            control_center.update_surface_display(player, surface_index)
            return
        elseif action == "quick_select_surface" then
            local surface_index = element.tags.surface_index
            control_center.update_surface_display(player, surface_index)
            return
        elseif action == "toggle_vehicle_filter" then
            local vehicle_name = element.tags.vehicle_name
            local main_frame = player.gui.screen.vehicle_control_center
            if main_frame and main_frame.tags then
                element.toggled = not element.toggled
                local surface_index = main_frame.tags.current_surface_index
                if surface_index then
                    control_center.update_surface_display(player, surface_index)
                else
                    control_center.update_surface_display(player, player.surface.index)
                end
            end
            return
        elseif action == "select_tab" then
            local vehicle_type = element.tags.vehicle_type
            control_center.update_vehicle_type_display(player, vehicle_type)
            return
        elseif action == "render" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            remote.call("vehicle-control-center", "render_vehicle", {
                player_index = player.index,
                unit_number = unit_number,
                surface_index = surface_index
            })
            return
        elseif action == "vcc_connect" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.connect_to_vehicle(player, unit_number, surface_index)
            return
        elseif action == "locate_vehicle" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.create_locator_arrow(player, unit_number, surface_index)
            return
        elseif action == "view_inventory" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.open_vehicle_inventory(player, unit_number, surface_index)
            return
        elseif action == "get_remote" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.get_spidertron_remote(player, unit_number, surface_index)
            return
        elseif action == "call_spidertron" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.call_spidertron_to_location(player, unit_number, surface_index)
            return
        elseif action == "follow_vehicle" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.follow_vehicle_in_map(player, unit_number, surface_index)
            return
        elseif action == "toggle_train_mode" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            local locomotive = find_vehicle_by_unit_number(unit_number, surface_index)
            if not locomotive or not locomotive.valid or locomotive.type ~= "locomotive" then
                player.print({"vcc.locomotive-not-found"})
                return
            end
            if locomotive.train then
                locomotive.train.manual_mode = not locomotive.train.manual_mode
                local is_automatic = not locomotive.train.manual_mode
                element.sprite = is_automatic and "virtual-signal/signal-A" or "virtual-signal/signal-M"
                element.tooltip = is_automatic and {"vcc.train-mode-automatic"} or {"vcc.train-mode-manual"}
                element.toggled = is_automatic
                if is_automatic then
                    player.print({"vcc.train-switched-to-automatic"})
                else
                    player.print({"vcc.train-switched-to-manual"})
                end
            else
                player.print({"vcc.train-not-found"})
            end
            return
        end
    end
end)

-- Handle GUI hover events
script.on_event(defines.events.on_gui_elem_changed, function(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    
    if not player or not element or not element.valid then return end
    
    log_debug("GUI Hover: " .. element.name)
    
    -- Track current hovered vehicle icon
    local player_data = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index] = player_data
    
    -- Close existing camera GUI if hovering over a different element
    if player_data.last_hovered_vehicle and (not element.tags or element.tags.action ~= "open_vehicle_camera") then
        if player.gui.screen.vehicle_camera_frame then
            player.gui.screen.vehicle_camera_frame.destroy()
        end
        player_data.last_hovered_vehicle = nil
    end
    
    -- Handle hover on vehicle icon
    if element.tags and element.tags.action == "open_vehicle_camera" then
        local unit_number = element.tags.unit_number
        local surface_index = element.tags.surface_index
        local vehicle = find_vehicle_by_unit_number(unit_number, surface_index)
        
        if vehicle and vehicle.valid then
            -- Only create new GUI if not already showing this vehicle
            if player_data.last_hovered_vehicle ~= unit_number then
                control_center.create_vehicle_camera_gui(player, {
                    entity = vehicle,
                    name = vehicle.name,
                    position = vehicle.position,
                    surface_index = surface_index
                })
                player_data.last_hovered_vehicle = unit_number
            end
        else
            player.print("Vehicle not found or invalid")
            -- Close camera GUI if vehicle is invalid
            if player.gui.screen.vehicle_camera_frame then
                player.gui.screen.vehicle_camera_frame.destroy()
            end
            player_data.last_hovered_vehicle = nil
        end
    end
end)

script.on_event(defines.events.on_gui_opened, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
        return
    end
    refresh_context_toolbars_for_player(player)
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
    local element = event.element
    if not element or not element.valid or element.name ~= "vehicle_control_center" then
        return
    end
    local player = game.get_player(event.player_index)
    if player and player.valid and control_center.remember_gui_location then
        control_center.remember_gui_location(player, element.location)
    end
end)

-- Handle GUI close events
script.on_event(defines.events.on_gui_closed, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    -- Check if the closed element is our GUI
    if event.element and (event.element.name == "vehicle_control_center" or event.element.name == "vehicle_camera_frame") then
        control_center.close_gui(player)
        -- Close camera GUI if open
        if player.gui.screen.vehicle_camera_frame then
            player.gui.screen.vehicle_camera_frame.destroy()
        end
        -- Clear last hovered vehicle
        local player_data = storage.vcc.players[event.player_index]
        if player_data then
            player_data.last_hovered_vehicle = nil
        end
    end

    refresh_context_toolbars_for_player(player)
end)

-- Handle tick events
script.on_event(defines.events.on_tick, function(event)
    for player_index, player_data in pairs(storage.vcc.players) do
        local player = game.get_player(player_index)
        if not player or not player.valid then goto continue end
        if player_data.following_vehicle and player.controller_type == defines.controllers.remote then
            local vehicle = find_vehicle_by_unit_number(player_data.following_vehicle_id, player_data.following_vehicle_surface)
            if vehicle and vehicle.valid then
                local success, error = pcall(function()
                    player.centered_on = vehicle
                end)
                if not success then
                    player.print("Failed to update vehicle view: " .. tostring(error))
                end
                player_data.remote_position = vehicle.position
                player_data.remote_surface = vehicle.surface
            else
                player_data.following_vehicle = false
                player_data.following_vehicle_id = nil
                player_data.following_vehicle_surface = nil
                local success, error = pcall(function()
                    player.centered_on = nil
                end)
                if not success then
                    player.print("Failed to exit remote view: " .. tostring(error))
                    pcall(function()
                        player.set_controller({type = player_data.physical_controller_type or defines.controllers.character})
                    end)
                end
            end
        end
        ::continue::
    end

    if event.tick % 10 == 0 then
        storage.vcc.remote_toolbar_state = storage.vcc.remote_toolbar_state or {}
        for _, player in pairs(game.connected_players) do
            if player and player.valid then
                local signature = make_remote_selection_signature(player)
                local previous = storage.vcc.remote_toolbar_state[player.index]
                if previous ~= signature then
                    storage.vcc.remote_toolbar_state[player.index] = signature
                    refresh_context_toolbars_for_player(player)
                end
            end
        end
    end
end)

-- Handle hover enter events
script.on_event(defines.events.on_gui_hover, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid or not event.element or not event.element.valid then
        log_debug("on_gui_hover: Invalid player or element")
        return
    end
    
    local element = event.element
    log_debug("on_gui_hover: Element: " .. element.name)
    
    if element.tags and element.tags.action == "open_vehicle_camera" then
        local unit_number = element.tags.unit_number
        local surface_index = element.tags.surface_index
        log_debug("Hover on vehicle icon: vehicle_" .. unit_number)
        
        local vehicle = find_vehicle_by_unit_number(unit_number, surface_index)
        if not vehicle or not vehicle.valid then
            log_debug("Vehicle not found for unit_number: " .. unit_number)
            player.print("Vehicle not found or invalid")
            return
        end
        
        local player_data = storage.vcc.players[player.index] or {}
        storage.vcc.players[player.index] = player_data
        
        local main_frame = player.gui.screen.vehicle_control_center
        if not main_frame then
            log_debug("Main frame not found")
            return
        end
        local gui_pos = main_frame.location
        local vehicle_list = main_frame.main_content.vehicle_list
        local row_index = 0
        for i, child in ipairs(vehicle_list.children) do
            if child.name == "vehicle_" .. unit_number then
                row_index = i
                break
            end
        end
        local button_position = {
            x = gui_pos.x + 60,
            y = gui_pos.y + 100 + (row_index * 32)
        }
        log_debug("Hover button position: " .. serpent.line(button_position))
        
        if player_data.last_hovered_vehicle ~= unit_number then
            log_debug("Creating hover camera GUI for vehicle: " .. vehicle.name)
            control_center.create_hover_camera_gui(player, {
                entity = vehicle,
                name = vehicle.name,
                position = vehicle.position,
                surface_index = surface_index
            }, button_position)
            player_data.last_hovered_vehicle = unit_number
        end
    end
end)

script.on_event(defines.events.on_gui_leave, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid or not event.element or not event.element.valid then
        log_debug("on_gui_leave: Invalid player or element")
        return
    end
    
    local element = event.element
    log_debug("on_gui_leave: Element: " .. element.name)
    
    local player_data = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index] = player_data
    
    if element.tags and element.tags.action == "open_vehicle_camera" and player_data.last_hovered_vehicle then
        log_debug("Leaving vehicle icon: vehicle_" .. player_data.last_hovered_vehicle)
        if player.gui.screen.vehicle_camera_frame then
            player.gui.screen.vehicle_camera_frame.destroy()
        end
        player_data.last_hovered_vehicle = nil
    end
end)

-- Detect WASD movement in remote mode
script.on_event(defines.events.on_player_changed_position, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end

    local player_data = storage.vcc.players[event.player_index]
    if not player_data or not player_data.following_vehicle then return end

    if player.controller_type == defines.controllers.remote then
        player_data.following_vehicle = false
        player_data.following_vehicle_id = nil
        player_data.following_vehicle_surface = nil
        player.centered_on = nil
        player.print("Stopped following vehicle")
    end
end)

-- Handler for map closed event
script.on_event(defines.events.on_player_left_game, function(event)
    local player_index = event.player_index
    local player_data = storage.vcc.players[player_index]
    
    if not player_data then return end
    
    if player_data.locator_id then
        if player_data.locator_id.valid then
            player_data.locator_id.destroy()
        end
        player_data.locator_id = nil
    end
    
    player_data.following_vehicle = false
    player_data.following_vehicle_id = nil
    player_data.following_vehicle_surface = nil
    
    player_data.viewing_inventory = false
    player_data.inventory_vehicle_id = nil
    player_data.inventory_surface_index = nil
end)

local function render_vehicle_remote(data)
    local player = game.get_player(data.player_index)
    local unit_number = data.unit_number
    local surface_index = data.surface_index
    
    local surface = game.surfaces[surface_index]
    local vehicle = nil
    
    for _, entity in pairs(surface.find_entities_filtered{type = {"spider-vehicle", "car", "locomotive"}}) do
        if entity.unit_number == unit_number then
            vehicle = entity
            break
        end
    end
    
    if not vehicle then
        player.print("Vehicle not found")
        return false
    end
    
    local position = vehicle.position
    player.set_controller({
        type = defines.controllers.remote,
        position = position,
        surface = surface
    })
    return true
end

--- Same as VCC GUI row "call spidertron": sets autopilot to player.position
--- (where you are looking in remote view).
local function call_spidertron_to_location_remote(data)
    local player = game.get_player(data.player_index)
    if not player or not player.valid then
        return false
    end
    local unit_number = data.unit_number or data.spidertron_unit_number
    local surface_index = data.surface_index
    if not unit_number or not surface_index then
        return false
    end
    if control_center.call_spidertron_to_location then
        control_center.call_spidertron_to_location(player, unit_number, surface_index)
    end
    return true
end

--- Same as VCC GUI "follow on map": closes inventories / VCC, then centers map view on the vehicle.
local function follow_vehicle_in_map_remote(data)
    local player = game.get_player(data.player_index)
    if not player or not player.valid then
        return false
    end
    local unit_number = data.unit_number or data.vehicle_unit_number
    local surface_index = data.surface_index
    if not unit_number or not surface_index then
        return false
    end
    if control_center.follow_vehicle_in_map then
        control_center.follow_vehicle_in_map(player, unit_number, surface_index)
    end
    return true
end

local function open_control_center_remote(player_index)
    local player = game.get_player(player_index)
    if not player or not player.valid then
        return false
    end
    control_center.open_gui(player)
    return true
end

--- Same as VCC GUI row "get remote": gives a linked spidertron remote on cursor.
local function vcc_click_get_remote(payload)
    local player = payload and game.get_player(payload.player_index)
    if not player or not player.valid then
        return false
    end
    local tags = payload.button_tags or {}
    local unit_number = tags.unit_number or tags.vehicle_unit_number
    local surface_index = tags.surface_index
    if (not unit_number or not surface_index) and payload.vehicle then
        unit_number = payload.vehicle.unit_number
        surface_index = payload.vehicle.surface_index
    end
    if not unit_number or not surface_index then
        return false
    end
    control_center.get_spidertron_remote(player, unit_number, surface_index)
    return true
end

local function refresh_context_buttons_remote(player_index)
    if player_index then
        local player = game.get_player(player_index)
        if player and player.valid then
            refresh_context_toolbars_for_player(player)
        end
        return true
    end
    for _, player in pairs(game.players) do
        if player and player.valid then
            refresh_context_toolbars_for_player(player)
        end
    end
    return true
end

local function register_button_compat(mod_id, config)
    if type(config) ~= "table" then
        return false
    end
    return register_context_button(mod_id, config.action, {
        context = "vehicle_relative",
        vehicle_types = {config.vehicle_type},
        priority = config.priority or 100,
        sprite = config.sprite or "utility/questionmark",
        tooltip = config.tooltip,
        style = config.style or "slot_sized_button",
        callback_interface = mod_id,
        click_action = config.callback
    })
end

local vehicle_control_center_interface = {
    render_vehicle = render_vehicle_remote,
    open_control_centre = open_control_center_remote,
    open_control_center = open_control_center_remote,
    call_spidertron_to_location = call_spidertron_to_location_remote,
    follow_vehicle_in_map = follow_vehicle_in_map_remote,
    vcc_click_get_remote = vcc_click_get_remote,
    register_context_button = register_context_button,
    unregister_context_button = unregister_context_button,
    refresh_context_buttons = refresh_context_buttons_remote,
    register_button = register_button_compat
}

remote.add_interface("vehicle-control-center", vehicle_control_center_interface)
remote.add_interface("vehicle-control-centre", vehicle_control_center_interface)

-- Handle GUI selection changes
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    
    if not player or not element or not element.valid then return end
    
    if control_center.on_gui_selection_state_changed then
        control_center.on_gui_selection_state_changed(event)
    end
end)

-- Handle cursor changes (for closing dropdowns when clicking away)
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
    local player = game.get_player(event.player_index)
    
    if control_center.on_player_cursor_stack_changed then
        control_center.on_player_cursor_stack_changed(event)
    end

    refresh_context_toolbars_for_player(player)
end)

script.on_event(defines.events.on_player_used_spidertron_remote, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
        return
    end
    storage.vcc.remote_toolbar_state = storage.vcc.remote_toolbar_state or {}
    storage.vcc.remote_toolbar_state[player.index] = make_remote_selection_signature(player)
    refresh_context_toolbars_for_player(player)
end)

script.on_event(defines.events.on_selected_entity_changed, function(event)
    local player = game.get_player(event.player_index)
    refresh_context_toolbars_for_player(player)
end)

-- Handle keyboard shortcuts
script.on_event("vcc-toggle", function(event)
    local player = game.get_player(event.player_index)
    if player then
        control_center.toggle_gui(player)
    end
end)

-- Handle shortcut bar button
script.on_event(defines.events.on_lua_shortcut, function(event)
    if event.prototype_name == "vcc-toggle" then
        local player = game.get_player(event.player_index)
        if player then
            control_center.toggle_gui(player)
        end
    end
end)

commands.add_command("vcc-open", "Open the Vehicle Control Center", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if player then
            control_center.toggle_gui(player)
        end
    end
end)

if control_center.set_scan_function then
    control_center.set_scan_function(scan_for_vehicles)
end