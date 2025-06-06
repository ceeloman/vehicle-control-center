-- control.lua for Vehicle Control Center mod

-- Load modules
local control_center = require("scripts.control_center")

local function log_debug(message)
    log("[Vehicle Control Center] " .. message)
end

-- Check if Neural Spider Control mod is present
local neural_mod_present = script.active_mods["neural-spider-control"] ~= nil

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

-- Event handlers

-- Handle new players
script.on_event(defines.events.on_player_created, function(event)
    local player = game.get_player(event.player_index)
end)

-- Handle configuration changes
script.on_configuration_changed(function(data)
    log_debug("Configuration changed")
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
    
    if player_data.locator_id and rendering.is_valid(player_data.locator_id) then
        rendering.clear(player_data.locator_id)
        player_data.locator_id = nil
    end
    
    player_data.following_vehicle = false
    player_data.following_vehicle_id = nil
    player_data.following_vehicle_surface = nil
    
    player_data.viewing_inventory = false
    player_data.inventory_vehicle_id = nil
    player_data.inventory_surface_index = nil
end)

remote.add_interface("vehicle-control-center", {
    render_vehicle = function(data)
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
})

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