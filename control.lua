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
        --player.print("Surface not found")
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
        --player.print("Vehicle not found")
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
        --player.print("Failed to connect: Neural Spider Control mod may be missing or not properly loaded.")
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
                -- Update player view position to follow vehicle
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

-- Handle tagged buttons
script.on_event(defines.events.on_gui_click, function(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    
    if not player or not element or not element.valid then return end
    
    log_debug("GUI Click: " .. element.name)
    
    -- Extract action from tags if present
    local action = element.tags and element.tags.action

    
    -- Handle close buttons
    if element.name == "vcc_close_button" or element.name == "close_vehicle_control_center" then
        control_center.close_gui(player)
        return
    end
    
    -- Handle refresh button
    if element.name == "vcc_refresh_button" then
        scan_for_vehicles()
        
        -- Recreate the GUI with current settings
        local player_data = storage.vcc.players[player.index]
        local vehicle_type = player_data and storage.vcc.last_vehicle_type[player.index] or "all"
        
        control_center.create_gui(player, vehicle_type)
        return
    end
    
    -- Handle actions from tags
    if action then
        -- Surface selector
        if action == "surface_selector" then
            -- Toggle surface dropdown
            control_center.create_surface_dropdown(player)
            return
        elseif action == "select_surface" then
            -- Change to selected surface
            local surface_index = element.tags.surface_index
            control_center.update_surface_display(player, surface_index)
            return
        elseif action == "quick_select_surface" then
            -- Quick surface selection
            local surface_index = element.tags.surface_index
            control_center.update_surface_display(player, surface_index)
            return
        elseif element.tags and element.tags.action == "toggle_vehicle_filter" then
            -- Handle toggle vehicle filter
            local vehicle_name = element.tags.vehicle_name
    
            -- Get the main frame and its tags
            local main_frame = player.gui.screen.vehicle_control_center
            if main_frame and main_frame.tags then
                -- Toggle the state in the GUI
                element.toggled = not element.toggled
                
                -- Get current surface index from the main_frame.tags, not player's surface
                local surface_index = main_frame.tags.current_surface_index
                
                if surface_index then
                    -- Update display with new filter settings, keeping the same surface
                    control_center.update_surface_display(player, surface_index)
                else
                    -- Fallback to player's surface if no surface index is stored
                    control_center.update_surface_display(player, player.surface.index)
                end
            end
            return
        elseif action == "select_tab" then
            -- Change vehicle type filter
            local vehicle_type = element.tags.vehicle_type
            control_center.update_vehicle_type_display(player, vehicle_type)
            return
        elseif action == "render" then
            -- Call the render_vehicle function through remote interface
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            
            remote.call("vehicle-control-center", "render_vehicle", {
                player_index = player.index,
                unit_number = unit_number,
                surface_index = surface_index
            })
            return
        elseif action == "vcc_connect" then
            -- Connect to a vehicle
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            
            connect_to_vehicle(player, unit_number, surface_index)
            return
        elseif action == "locate_vehicle" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.create_locator_arrow(player, unit_number, surface_index)
            return
        
        -- Handle view inventory button
        elseif action == "view_inventory" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.open_vehicle_inventory(player, unit_number, surface_index)
            return
        
        -- Handle get remote button
        elseif action == "get_remote" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.get_spidertron_remote(player, unit_number, surface_index)
            return
        
        -- Handle call spidertron button
        elseif action == "call_spidertron" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.call_spidertron_to_location(player, unit_number, surface_index)
            return
        
        -- Handle follow vehicle in map button
        elseif action == "follow_vehicle" then
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            control_center.follow_vehicle_in_map(player, unit_number, surface_index)
            return
        elseif action == "toggle_train_mode" then
            --player.print({"toggle train mode"})
            local unit_number = element.tags.unit_number
            local surface_index = element.tags.surface_index
            
            -- Find the locomotive using the provided function
            local locomotive = find_vehicle_by_unit_number(unit_number, surface_index)
            if not locomotive or not locomotive.valid or locomotive.type ~= "locomotive" then
                --player.print({"vcc.locomotive-not-found"})
                return
            end
            
            -- Toggle the train's manual mode
            if locomotive.train then
                locomotive.train.manual_mode = not locomotive.train.manual_mode
                
                -- Update the button appearance
                local is_automatic = not locomotive.train.manual_mode
                element.sprite = is_automatic and "virtual-signal/signal-A" or "virtual-signal/signal-M"
                element.tooltip = is_automatic and {"vcc.train-mode-automatic"} or {"vcc.train-mode-manual"}
                
                -- Set toggled state based on mode
                element.toggled = is_automatic
                
                -- Show feedback to the player
                if is_automatic then
                    --player.print({"vcc.train-switched-to-automatic"})
                else
                    --player.print({"vcc.train-switched-to-manual"})
                end
            else
                --player.print({"vcc.train-not-found"})
            end
            return
        end
    end

end)

script.on_event(defines.events.on_tick, function(event)
    for player_index, player_data in pairs(storage.vcc.players) do -- line 400
        local player = game.get_player(player_index)
        if not player or not player.valid then goto continue end

        if player_data.following_vehicle and player.controller_type == defines.controllers.remote then
            local vehicle = find_vehicle_by_unit_number(player_data.following_vehicle_id, player_data.following_vehicle_surface)
            
            if vehicle and vehicle.valid then
                local success, error = pcall(function()
                    player.centered_on = vehicle
                end)
                if not success then
                    --player.print("Failed to update vehicle view: " .. tostring(error))
                end
                -- Update remote position
                player_data.remote_position = vehicle.position
                player_data.remote_surface = vehicle.surface
            else
                -- Vehicle invalid, exit remote view
                player_data.following_vehicle = false
                player_data.following_vehicle_id = nil
                player_data.following_vehicle_surface = nil
                
                local success, error = pcall(function()
                    player.centered_on = nil
                end)
                if not success then
                    --player.print("Failed to exit remote view: " .. tostring(error))
                    pcall(function()
                        player.set_controller({type = player_data.physical_controller_type or defines.controllers.character})
                    end)
                end
            end
        end

        if player_data.locator_timer and game.tick >= player_data.locator_timer then
            if player_data.locator_id then
                --rendering.clear(player_data.locator_id)
                player_data.locator_id = nil
                player_data.locator_vehicle_id = nil
            end
            player_data.locator_timer = nil
        end

        ::continue::
    end
end)

-- Detect WASD movement in remote mode
script.on_event(defines.events.on_player_changed_position, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end

    local player_data = storage.vcc.players[event.player_index]
    if not player_data or not player_data.following_vehicle then return end

    if player.controller_type == defines.controllers.remote then
        -- Stop following vehicle but stay in remote mode
        player_data.following_vehicle = false
        player_data.following_vehicle_id = nil
        player_data.following_vehicle_surface = nil
        player.centered_on = nil -- Clear centering but stay in remote mode
        --player.print("Stopped following vehicle")
    end
end)

-- Add this to your script event registration
script.on_event(defines.events.on_gui_closed, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    -- Check if the closed element is our GUI
    if event.element and event.element.name == "vehicle_control_center" then
        control_center.close_gui(player)
    end
end)

-- Handler for map closed event
script.on_event(defines.events.on_player_left_game, function(event)
    local player_index = event.player_index
    local player_data = storage.vcc.players[player_index]
    
    if not player_data then return end
    
    -- Clean up any rendering
    if player_data.locator_id and rendering.is_valid(player_data.locator_id) then
        rendering.clear(player_data.locator_id)
        player_data.locator_id = nil
    end
    
    -- Reset follow status
    player_data.following_vehicle = false
    player_data.following_vehicle_id = nil
    player_data.following_vehicle_surface = nil
    
    -- Reset inventory view status
    player_data.viewing_inventory = false
    player_data.inventory_vehicle_id = nil
    player_data.inventory_surface_index = nil
end)

remote.add_interface("vehicle-control-center", {
    render_vehicle = function(data)
        -- Get player and unit_number from the data
        local player = game.get_player(data.player_index)
        local unit_number = data.unit_number
        local surface_index = data.surface_index
        
        -- Find the vehicle
        local surface = game.surfaces[surface_index]
        local vehicle = nil
        
        for _, entity in pairs(surface.find_entities_filtered{type = {"spider-vehicle", "car", "locomotive"}}) do
            if entity.unit_number == unit_number then
                vehicle = entity
                break
            end
        end
        
        if not vehicle then
            --player.print("Vehicle not found")
            return false
        end
        
        -- Get position and show the location
        local position = vehicle.position
        ----player.print("Showing " .. vehicle.name .. " at " .. position.x .. ", " .. position.y)
        
        -- Set to remote controller centered on the vehicle
        player.set_controller({
            type = defines.controllers.remote,
            position = position,
            surface = surface
        })
        
        -- Set zoom level after switching to remote controller
        -- Smaller values = more zoomed in (0.5 is fairly close)
        --player.zoom = 0.5
        ----player.print("Using remote view. Press ESC to return to normal view.")
        return true
    end
})

-- Handle GUI selection changes
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    
    if not player or not element or not element.valid then return end
    
    -- Pass to control center
    if control_center.on_gui_selection_state_changed then
        control_center.on_gui_selection_state_changed(event)
    end
end)

-- Handle cursor changes (for closing dropdowns when clicking away)
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
    local player = game.get_player(event.player_index)
    
    -- Pass to control center
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

-- Periodic scan
--[[
script.on_nth_tick(60, function(event)
    -- Update vehicle scan every second
    scan_for_vehicles()
    
    -- Update GUIs for players with open interfaces
    for player_index, player_data in pairs(storage.vcc.players) do
        if player_data.gui_open then
            local player = game.get_player(player_index)
            if player and player.valid and player.gui.screen.vehicle_control_center then
                -- Get the main frame
                local main_frame = player.gui.screen.vehicle_control_center
                local vehicle_type = main_frame.tags and main_frame.tags.vehicle_type or "all"
                local surface_index = main_frame.tags and main_frame.tags.current_surface_index or player.surface.index
                
                -- Recreate the GUI to refresh it
                control_center.create_gui(player, vehicle_type)
            end
        end
    end
end)


-- Admin commands
commands.add_command("vcc-scan", "Rescan for vehicles", function(command)
    scan_for_vehicles()
    if command.player_index then
        local player = game.get_player(command.player_index)
        if player then
            --player.print("Vehicle scan complete")
        end
    end
end)
]]

commands.add_command("vcc-open", "Open the Vehicle Control Center", function(command)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if player then
            control_center.toggle_gui(player)
        end
    end
end)

-- Provide scan function to control center
if control_center.set_scan_function then
    control_center.set_scan_function(scan_for_vehicles)
end