-- scripts/control_center.lua
local mod_gui = require("mod-gui")
local space_age_installed = script.active_mods["space-age"] ~= nil

local control_center = {}
local scan_vehicles_function

local function log_debug(message)
    log("[Vehicle Control Center] " .. message)
end

local function debug_vehicle_filters(player)
    local main_frame = player.gui.screen.vehicle_control_center
    if not main_frame or not main_frame.tags or not main_frame.tags.vehicle_filters then
        log_debug("No vehicle filters found in main frame")
        return
    end
    
    log_debug("Current vehicle filters for player " .. player.name .. ":")
    for name, info in pairs(main_frame.tags.vehicle_filters) do
        log_debug("  - " .. name .. ": " .. tostring(info.enabled))
    end
    
    if storage.vcc.vehicle_filters and storage.vcc.vehicle_filters[player.index] then
        log_debug("Stored vehicle filters:")
        for name, enabled in pairs(storage.vcc.vehicle_filters[player.index]) do
            log_debug("  - " .. name .. ": " .. tostring(enabled))
        end
    else
        log_debug("No stored vehicle filters")
    end
end

-- Function to set the scan function from control.lua
function control_center.set_scan_function(func)
    scan_vehicles_function = func
end

-- Helper function to get display name for a vehicle
function get_display_name(vehicle)
    if not vehicle or not vehicle.entity or not vehicle.entity.valid then
        return "Invalid Vehicle"
    end
    
    -- Check if it has an entity label (backer_name)
    if vehicle.entity.entity_label and vehicle.entity.entity_label ~= "" then
        return vehicle.entity.entity_label
    end
    
    -- Return a formatted name if no label
    return vehicle.entity.name:gsub("%-", " "):gsub("^%l", string.upper)
end

-- Helper function to format surface name with Space Age compatibility
local function format_surface_name(surface_name)
    -- Convert to lowercase for comparison
    local lower_name = string.lower(surface_name)
    
    -- Format with proper capitalization
    local formatted_name = string.gsub(" "..surface_name, "%W%l", string.upper):sub(2)
    
    -- Try to detect if it's a planet or a space location based on common patterns
    local is_likely_planet = false
    
    -- Check if it matches known planet patterns
    if string.match(lower_name, "moon") or 
       string.match(lower_name, "planet") or
       not string.match(lower_name, "[%s%-]") then  -- Single word names are likely planets
        is_likely_planet = true
    end
    
    -- Check for known Space Age planets explicitly
    local known_planets = {
        ["nauvis"] = true,
        ["gleba"] = true, 
        ["fulgora"] = true,
        ["vulcanus"] = true,
        ["aquilo"] = true
    }
    
    local known_locations = {
        ["solar-system-edge"] = true,
        ["shattered-planet"] = true
    }
    
    if known_planets[lower_name] then
        is_likely_planet = true
    elseif known_locations[lower_name] then
        is_likely_planet = false
    end
    
    -- Format name with proper capitalization
    local display_name = formatted_name
    
    -- Use appropriate rich text formatting with name included
    if is_likely_planet then
        return {
            type = "planet",
            name = lower_name,
            display_name = display_name,
            formatted = "[planet=" .. lower_name .. "] " .. display_name
        }
    else
        return {
            type = "location", 
            name = lower_name,
            display_name = display_name,
            formatted = "[space-location=" .. lower_name .. "] " .. display_name
        }
    end
end

-- Helper function to get sprite for surface type
local function get_surface_sprite(surface_info)
    if surface_info.type == "planet" then
        -- Try to get specific planet sprite if it exists
        local specific_sprite = "item/planet-" .. surface_info.name
        -- Default to generic planet
        return specific_sprite
    else
        -- Space location sprite
        return "item/space-platform"
    end
end

local function add_neural_connect_button(vehicle_buttons_flow, vehicle)
    if script.active_mods["neural-spider-control"] then
        local connect_button = vehicle_buttons_flow.add{
            type = "sprite-button",
            sprite = "neural-connection-sprite",
            tooltip = {"vcc-gui.neural-connect-tooltip"},
            tags = {
                action = "vcc_connect",
                unit_number = vehicle.unit_number,
                surface_index = vehicle.surface.index
            }
        }
        connect_button.style.size = 28
        
        -- Disable if vehicle is occupied
        if vehicle.get_driver() then
            connect_button.enabled = false
            connect_button.tooltip = {"vcc-gui.neural-connect-occupied"}
        end
    end
end

function control_center.create_locator_arrow(player, vehicle_unit_number, surface_index)
    if not player or not player.valid then return end

    local vehicle = find_vehicle_by_unit_number(vehicle_unit_number, surface_index)
    if not vehicle or not vehicle.valid then
        --player.print({"vcc-gui.vehicle-not-found"})
        return
    end

    if vehicle.surface.index ~= player.surface.index then
        --player.print("Vehicle not on this surface")
        return
    end

    if storage.vcc.players[player.index] and storage.vcc.players[player.index].locator_id then
        local locator_id = storage.vcc.players[player.index].locator_id
        rendering.clear("vehicle-control-center")
        storage.vcc.players[player.index].locator_id = nil
        storage.vcc.players[player.index].locator_vehicle_id = nil
    end

    local view_position = player.position
    local dx = vehicle.position.x - view_position.x
    local dy = vehicle.position.y - view_position.y
    local orientation = math.atan2(dy, dx) / (2 * math.pi)
    if orientation < 0 then orientation = orientation + 1 end

    -- Offset by 1 tile in the direction of the vehicle
    local offset_distance = 3
    local offset_position = {
        x = view_position.x + offset_distance * math.cos(orientation * 2 * math.pi),
        y = view_position.y + offset_distance * math.sin(orientation * 2 * math.pi)
    }

    -- Rotate sprite 90 degrees clockwise (add 0.25 to orientation)
    local sprite_orientation = (orientation + 0.25) % 1

    local arrow_id = rendering.draw_sprite{
        sprite = "utility/alert_arrow",
        target = offset_position,
        surface = player.surface,
        players = {player.index},
        x_scale = 1.5,
        y_scale = 1.5,
        render_layer = "light-effect",
        orientation = sprite_orientation,
        time_to_live = 300
    }

    storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index].locator_id = arrow_id
    storage.vcc.players[player.index].locator_vehicle_id = vehicle_unit_number
    storage.vcc.players[player.index].locator_timer = game.tick + 60 * 60

    --player.print({"vcc-gui.locator-arrow-created"})
end

-- Add to control_center.lua - New function for opening a vehicle's inventory GUI
function control_center.open_vehicle_inventory(player, vehicle_unit_number, surface_index)
    if not player or not player.valid then return end

    local vehicle = find_vehicle_by_unit_number(vehicle_unit_number, surface_index)
    if not vehicle or not vehicle.valid then
        --player.print({"vcc-gui.vehicle-not-found"})
        return
    end

    storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index].physical_controller_type = player.controller_type

    -- Set remote view centered on vehicle
    local success, error = pcall(function()
        player.centered_on = vehicle
    end)
    if not success then
        --player.print("Failed to center on vehicle: " .. tostring(error))
        return
    end

    -- Open vehicle inventory GUI
    success, error = pcall(function()
        player.opened = vehicle
    end)
    if not success then
        --player.print("Failed to open vehicle inventory: " .. tostring(error))
        return
    end

    storage.vcc.players[player.index].viewing_inventory = true
    storage.vcc.players[player.index].inventory_vehicle_id = vehicle.unit_number
    storage.vcc.players[player.index].inventory_surface_index = surface_index
    storage.vcc.players[player.index].inventory_timer = game.tick + 5
end

-- Add to control_center.lua - New function for getting a spidertron remote
function control_center.get_spidertron_remote(player, spidertron_unit_number, surface_index)
    if not player or not player.valid then return end

    local spidertron = find_vehicle_by_unit_number(spidertron_unit_number, surface_index)
    if not spidertron or not spidertron.valid or spidertron.type ~= "spider-vehicle" then
        --player.print({"vcc-gui.spidertron-not-found"})
        return
    end

    local remote = player.cursor_stack

    -- If cursor is occupied, find an empty inventory slot
    if remote.valid_for_read then
        remote = player.get_main_inventory().find_empty_stack()
        if not remote then
            --player.print({"vcc-gui.inventory-full"})
            return
        end
    end

    -- Set the remote item
    local success, error = pcall(function()
        remote.set_stack({name = "spidertron-remote", count = 1})
    end)
    if not success then
        --player.print("Failed to create spidertron remote: " .. tostring(error))
        return
    end

    -- Connect remote to spidertron (simulate player linking)
    success, error = pcall(function()
        player.opened = spidertron
        player.cursor_stack.set_stack({name = "spidertron-remote", count = 1})
        player.opened = nil
    end)
    if not success then
        --player.print("Failed to connect remote to spidertron: " .. tostring(error))
        return
    end

    --player.print({"vcc-gui.remote-created", spidertron.prototype.localised_name})
end

-- Add to control_center.lua - New function for calling a spidertron to player's location
function control_center.get_spidertron_remote(player, spidertron_unit_number, surface_index)
    if not player or not player.valid then return end

    local spidertron = find_vehicle_by_unit_number(spidertron_unit_number, surface_index)
    if not spidertron or not spidertron.valid or spidertron.type ~= "spider-vehicle" then
        --player.print({"vcc-gui.spidertron-not-found"})
        return
    end

    local remote = player.cursor_stack

    -- If cursor is occupied, find an empty inventory slot
    if remote.valid_for_read then
        remote = player.get_main_inventory().find_empty_stack()
        if not remote then
            --player.print({"vcc-gui.inventory-full"})
            return
        end
    end

    -- Set the remote item
    local success, error = pcall(function()
        remote.set_stack({name = "spidertron-remote", count = 1})
    end)
    if not success then
        ----player.print("Failed to create spidertron remote: " .. tostring(error))
        return
    end

    -- Connect remote to spidertron
    success, error = pcall(function()
        player.spidertron_remote_selection = {spidertron}
    end)
    if not success then
        ----player.print("Failed to connect remote to spidertron: " .. tostring(error))
        return
    end

    ----player.print({"vcc-gui.remote-created", spidertron.prototype.localised_name})
end

-- Function to follow a vehicle in map view
function control_center.follow_vehicle_in_map(player, vehicle_unit_number, surface_index)
    if not player or not player.valid then return end

    -- Find vehicle
    local vehicle = find_vehicle_by_unit_number(vehicle_unit_number, surface_index)
    if not vehicle or not vehicle.valid then
        ----player.print({"vcc-gui.vehicle-not-found"})
        return
    end

    -- Close GUIs
    if player.gui.screen.vehicle_control_center then
        control_center.close_gui(player)
    end
    if player.opened then
        player.opened = nil -- Close chart mode or other GUIs
    end

    -- Store current controller type
    storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index].physical_controller_type = player.controller_type

    -- Exit remote view if already in it
    if player.controller_type == defines.controllers.remote then
        local success, error = pcall(function()
            player.centered_on = nil
        end)
        if not success then
            --player.print("Failed to exit remote view: " .. tostring(error))
            pcall(function()
                player.set_controller({type = defines.controllers.character})
            end)
        end
    end

    -- Center on vehicle
    local success, error = pcall(function()
        player.centered_on = vehicle
    end)
    if not success then
        --player.print("Failed to follow vehicle: " .. tostring(error))
        return
    end

    -- Save tracking info
    storage.vcc.players[player.index].following_vehicle = true
    storage.vcc.players[player.index].following_vehicle_id = vehicle_unit_number
    storage.vcc.players[player.index].following_vehicle_surface = surface_index
    storage.vcc.players[player.index].remote_position = vehicle.position
    storage.vcc.players[player.index].remote_surface = vehicle.surface

    ----player.print({"vcc-gui.following-vehicle-in-map"})
end

function control_center.call_spidertron_to_location(player, spidertron_unit_number, surface_index)
    if not player or not player.valid then return end

    local spidertron = find_vehicle_by_unit_number(spidertron_unit_number, surface_index)
    if not spidertron or not spidertron.valid or spidertron.type ~= "spider-vehicle" then
        --player.print({"vcc-gui.spidertron-not-found"})
        return
    end

    if spidertron.surface.index ~= surface_index then
        --player.print("Spidertron not on target surface")
        return
    end

    local target_position = player.position
    if not target_position or not target_position.x or not target_position.y then
        --player.print("Invalid target position")
        return
    end

    local success, error = pcall(function()
        spidertron.autopilot_destination = target_position
    end)
    if not success then
        --player.print("Failed to set spidertron destination: " .. tostring(error))
        return
    end

    --player.print({"vcc-gui.spidertron-called", spidertron.prototype.localised_name})
end

-- Helper function to get vehicles on a specific surface and of a specific type
local function get_valid_vehicles_on_surface(surface, player_force, vehicle_type)
    local vehicles = {}
    
    if vehicle_type == "spider-vehicle" or vehicle_type == "all" then
        -- Find all spider-vehicles
        local spidertrons = surface.find_entities_filtered{
            type = "spider-vehicle",
            force = player_force
        }
        
        for _, spidertron in ipairs(spidertrons) do
            if spidertron.valid then
                table.insert(vehicles, {
                    entity = spidertron,
                    unit_number = spidertron.unit_number,
                    position = spidertron.position,
                    type = "spider-vehicle",
                    name = spidertron.name,
                    get_driver = function() return spidertron.get_driver() end,
                    prototype = spidertron.prototype,
                    surface = surface
                })
            end
        end
    end
    
    if vehicle_type == "car" or vehicle_type == "all" then
        -- Find cars
        local cars = surface.find_entities_filtered{
            type = "car",
            force = player_force
        }
        
        for _, car in ipairs(cars) do
            if car.valid and car.prototype.allow_passengers then
                table.insert(vehicles, {
                    entity = car,
                    unit_number = car.unit_number,
                    position = car.position,
                    type = "car",
                    name = car.name,
                    get_driver = function() return car.get_driver() end,
                    prototype = car.prototype,
                    surface = surface
                })
            end
        end
    end
    
    if vehicle_type == "locomotive" or vehicle_type == "all" then
        -- Find locomotives
        local locomotives = surface.find_entities_filtered{
            type = "locomotive",
            force = player_force
        }
        
        for _, locomotive in ipairs(locomotives) do
            if locomotive.valid then
                table.insert(vehicles, {
                    entity = locomotive,
                    unit_number = locomotive.unit_number,
                    position = locomotive.position,
                    type = "locomotive",
                    name = locomotive.name,
                    get_driver = function() return locomotive.get_driver() end,
                    prototype = locomotive.prototype,
                    surface = surface
                })
            end
        end
    end
    
    return vehicles
end

-- Function to collect all surfaces with vehicles
local function collect_surfaces_with_vehicles(player_force, vehicle_type)
    local surfaces_data = {}
    
    log_debug("Collecting surfaces with vehicles for type: " .. vehicle_type)
    
    for _, surface in pairs(game.surfaces) do
        log_debug("Checking surface: " .. surface.name)
        
        -- Get spidertrons
        local spidertrons = {}
        if vehicle_type == "spider-vehicle" or vehicle_type == "all" then
            for _, entity in pairs(surface.find_entities_filtered{
                type = "spider-vehicle",
                force = player_force
            }) do
                if entity.valid then
                    table.insert(spidertrons, {
                        entity = entity,
                        unit_number = entity.unit_number,
                        position = entity.position,
                        type = "spider-vehicle",
                        name = entity.name,
                        surface = surface,
                        entity_label = entity.backer_name or "",
                        backer_name = entity.backer_name or "",
                        get_driver = function() return entity.get_driver() end
                    })
                    log_debug("Found spidertron: " .. entity.name .. " (#" .. entity.unit_number .. ")")
                end
            end
        end
        
        -- Get cars
        local cars = {}
        if vehicle_type == "car" or vehicle_type == "all" then
            for _, entity in pairs(surface.find_entities_filtered{
                type = "car",
                force = player_force
            }) do
                if entity.valid and entity.prototype.allow_passengers then
                    table.insert(cars, {
                        entity = entity,
                        unit_number = entity.unit_number,
                        position = entity.position,
                        type = "car",
                        name = entity.name,
                        surface = surface,
                        entity_label = entity.backer_name or "",
                        backer_name = entity.backer_name or "",
                        get_driver = function() return entity.get_driver() end
                    })
                    log_debug("Found car: " .. entity.name .. " (#" .. entity.unit_number .. ")")
                end
            end
        end
        
        -- Get locomotives
        local locomotives = {}
        if vehicle_type == "locomotive" or vehicle_type == "all" then
            for _, entity in pairs(surface.find_entities_filtered{
                type = "locomotive",
                force = player_force
            }) do
                if entity.valid then
                    table.insert(locomotives, {
                        entity = entity,
                        unit_number = entity.unit_number,
                        position = entity.position,
                        type = "locomotive",
                        name = entity.name,
                        surface = surface,
                        entity_label = entity.backer_name or "",
                        backer_name = entity.backer_name or "",
                        get_driver = function() return entity.get_driver() end
                    })
                    log_debug("Found locomotive: " .. entity.name .. " (#" .. entity.unit_number .. ")")
                end
            end
        end
        
        -- Combine all vehicles
        local all_vehicles = {}
        for _, v in ipairs(spidertrons) do table.insert(all_vehicles, v) end
        for _, v in ipairs(cars) do table.insert(all_vehicles, v) end
        for _, v in ipairs(locomotives) do table.insert(all_vehicles, v) end
        
        -- Only add surfaces that have vehicles
        if #all_vehicles > 0 then
            local surface_info = format_surface_name(surface.name)
            local surface_sprite = get_surface_sprite(surface_info)
            
            table.insert(surfaces_data, {
                surface = surface,
                vehicles = all_vehicles,
                surface_info = surface_info,
                sprite = surface_sprite
            })
            
            log_debug("Added surface " .. surface.name .. " with " .. #all_vehicles .. " vehicles")
        else
            log_debug("No matching vehicles found on surface " .. surface.name)
        end
    end
    
    -- Sort surfaces - planets first, then other locations
    table.sort(surfaces_data, function(a, b)
        if a.surface_info.type == b.surface_info.type then
            return a.surface_info.display_name < b.surface_info.display_name
        else
            return a.surface_info.type == "planet" -- Planets before locations
        end
    end)
    
    log_debug("Found " .. #surfaces_data .. " surfaces with vehicles")
    return surfaces_data
end

-- Helper function to add buttons to vehicle row
local function add_buttons_to_vehicle_row(row, vehicle, button_flow)
    -- Add map/render button
    --[[
    local render_button = button_flow.add{
        type = "sprite-button",
        sprite = "entity/radar",
        tooltip = {"vcc.view-on-map"},
        tags = {
            action = "render",
            unit_number = vehicle.unit_number,
            surface_index = vehicle.surface.index
        }
    }
    render_button.style.size = 28
    ]]
    -- Add map follow button (new)
    local follow_button = button_flow.add{
        type = "sprite-button",
        sprite = "utility/gps_map_icon",
        tooltip = {"vcc.follow-in-map"},
        tags = {
            action = "follow_vehicle",
            unit_number = vehicle.unit_number,
            surface_index = vehicle.surface.index
        }
    }
    follow_button.style.size = 28
    follow_button.style.left_margin = 10
    follow_button.style.vertical_align = "center"
    
    -- Add locator button (new)
    local locator_button = button_flow.add{
        type = "sprite-button",
        sprite = "utility/search",
        tooltip = {"vcc.locate-vehicle"},
        tags = {
            action = "locate_vehicle",
            unit_number = vehicle.unit_number,
            surface_index = vehicle.surface.index
        }
    }
    locator_button.style.size = 28
    
    -- Add inventory view button (new)
    local inventory_button = button_flow.add{
        type = "sprite-button",
        sprite = "entity/steel-chest",
        tooltip = {"vcc.view-inventory"},
        tags = {
            action = "view_inventory",
            unit_number = vehicle.unit_number,
            surface_index = vehicle.surface.index
        }
    }
    inventory_button.style.size = 28
    
    -- For spidertrons, add spidertron-specific buttons
    if vehicle.type == "spider-vehicle" then
        -- Add get remote button (new)
        local remote_button = button_flow.add{
            type = "sprite-button",
            sprite = "item/spidertron-remote",
            tooltip = {"vcc.get-remote"},
            tags = {
                action = "get_remote",
                unit_number = vehicle.unit_number,
                surface_index = vehicle.surface.index
            }
        }
        remote_button.style.size = 28
        
        -- Add call to location button (new)
        local call_button = button_flow.add{
            type = "sprite-button",
            sprite = "vcc-whistle",
            tooltip = {"vcc.call-spidertron"},
            tags = {
                action = "call_spidertron",
                unit_number = vehicle.unit_number,
                surface_index = vehicle.surface.index
            }
        }
        call_button.style.size = 28
        
        -- Disable the call button if spidertron is occupied
        if vehicle.get_driver() then
            call_button.enabled = false
            call_button.tooltip = {"vcc.spidertron-occupied"}
        end
    end
    
    -- Add neural connect button if neural mod is available (existing functionality)
    if script.active_mods["neural-spider-control"] then
        local connect_button = button_flow.add{
            type = "sprite-button",
            sprite = "neural-connection-sprite",
            tooltip = {"vcc.connect-tooltip"},
            tags = {
                action = "vcc_connect",
                unit_number = vehicle.unit_number,
                surface_index = vehicle.surface.index
            }
        }
        connect_button.style.size = 28
        
        -- Disable if vehicle is occupied
        if vehicle.get_driver() then
            connect_button.enabled = false
            connect_button.tooltip = {"vcc.connect-disabled-tooltip"}
        end
    end
    if vehicle.type == "locomotive" and vehicle.entity.train then
        local is_automatic = not vehicle.entity.train.manual_mode
        
        local mode_button = button_flow.add{
            type = "sprite-button",
            sprite = is_automatic and "virtual-signal/signal-A" or "virtual-signal/signal-M",
            tooltip = is_automatic and {"vcc.train-mode-automatic"} or {"vcc.train-mode-manual"},
            toggled = is_automatic,  -- Use toggled property for visual indication
            tags = {
                action = "toggle_train_mode",
                unit_number = vehicle.unit_number,
                surface_index = vehicle.surface.index
            }
        }
        
        mode_button.style.size = 28
    end
end

-- Create or update the control center GUI
function control_center.create_gui(player, vehicle_type)
    vehicle_type = vehicle_type or "all"
    
    if player.gui.screen.vehicle_control_center then 
        player.gui.screen.vehicle_control_center.destroy()
    end
    
    log_debug("Creating control center GUI for player: " .. player.name)
    
    -- Create main frame
    local main_frame = player.gui.screen.add{
        type = "frame", 
        name = "vehicle_control_center", 
        direction = "vertical"
    }

    player.opened = main_frame
    
    -- Position at left middle of screen
    main_frame.auto_center = false
    main_frame.location = {
        x = 50, 
        y = math.floor(player.display_resolution.height / 2) - 150
    }
    
    -- Add title bar with drag handle and close button
    local title_flow = main_frame.add{
        type = "flow",
        direction = "horizontal",
        name = "title_flow"
    }
    
    -- Add caption as label
    local title_label = title_flow.add{
        type = "label",
        caption = {"vcc.main-title"},
        style = "frame_title"
    }
    title_label.drag_target = main_frame
    
    -- Add draggable space
    local drag_handle = title_flow.add{
        type = "empty-widget",
        style = "draggable_space_header"
    }
    drag_handle.style.horizontally_stretchable = true
    drag_handle.style.height = 24
    drag_handle.style.right_margin = 4
    drag_handle.ignored_by_interaction = false
    drag_handle.drag_target = main_frame
    
    -- Add close button
    local close_button = title_flow.add{
        type = "sprite-button",
        name = "close_vehicle_control_center",
        sprite = "utility/close",
        hovered_sprite = "utility/close_black",
        clicked_sprite = "utility/close_black",
        tooltip = {"gui.close"},
        style = "frame_action_button"
    }
    
    -- Main content container
    local main_content = main_frame.add{
        type = "flow", 
        direction = "vertical",
        name = "main_content"
    }
    main_content.style.padding = {4, 4}
    
    -- Determine which surface to use
    -- Always use the player's current surface
    local current_surface = player.surface
    local current_surface_index = current_surface.index
    log_debug("Using player's current surface index: " .. current_surface_index)
    
    -- Get vehicles from the current surface
    local vehicles = {}
    if current_surface then
        vehicles = get_valid_vehicles_on_surface(current_surface, player.force, vehicle_type or "all")
        log_debug("Found " .. #vehicles .. " vehicles on surface " .. current_surface.name)
    end
    
    -- Get all surfaces with vehicles
    local surfaces_data = collect_surfaces_with_vehicles(player.force, vehicle_type)
    
    -- Add vehicle type selector section
    local vehicle_selector_flow = main_content.add{
        type = "flow",
        direction = "horizontal",
        name = "vehicle_selector_flow"
    }
    vehicle_selector_flow.style.vertical_align = "center"
    vehicle_selector_flow.style.margin = {0, 0, 8, 0}
    
    -- Vehicle type label
    local vehicle_label = vehicle_selector_flow.add{
        type = "label",
        caption = {"vcc.vehicle-type"}
    }
    vehicle_label.style.minimal_width = 100
    
    -- Create tab buttons with entity icons
    -- Spider vehicle tab (using spidertron icon)
    local spider_tab = vehicle_selector_flow.add{
        type = "sprite-button",
        name = "tab_spider",
        sprite = "entity/spidertron",
        tooltip = {"vcc.filter-spidertrons"},
        tags = {
            action = "select_tab",
            vehicle_type = "spider-vehicle"
        }
    }
    spider_tab.style.size = 40
    
    -- Car tab (using car icon)
    local car_tab = vehicle_selector_flow.add{
        type = "sprite-button",
        name = "tab_car",
        sprite = "entity/car",
        tooltip = {"vcc.filter-cars"},
        tags = {
            action = "select_tab",
            vehicle_type = "car"
        }
    }
    car_tab.style.size = 40
    
    -- Locomotive tab (using locomotive icon)
    local locomotive_tab = vehicle_selector_flow.add{
        type = "sprite-button",
        name = "tab_locomotive",
        sprite = "entity/locomotive",
        tooltip = {"vcc.filter-locomotives"},
        tags = {
            action = "select_tab",
            vehicle_type = "locomotive"
        }
    }
    locomotive_tab.style.size = 40
    
    -- Highlight the currently selected tab
    spider_tab.enabled = vehicle_type ~= "spider-vehicle"
    car_tab.enabled = vehicle_type ~= "car"
    locomotive_tab.enabled = vehicle_type ~= "locomotive"

    if space_age_installed or #game.surfaces > 1 then
        -- Surface selector section
        surface_selector_flow = main_content.add{
            type = "flow",
            direction = "horizontal",
            name = "surface_selector_flow"
        }
        surface_selector_flow.style.vertical_align = "center"
        surface_selector_flow.style.margin = {0, 0, 8, 0}

        -- Surface label
        surface_label = surface_selector_flow.add{
            type = "label",
            caption = {"vcc.current-surface"}
        }
        surface_label.style.minimal_width = 100

        -- Add planet buttons flow
        planet_buttons_flow = surface_selector_flow.add{
            type = "flow",
            name = "planet_buttons_flow",
            direction = "horizontal"
        }
        planet_buttons_flow.style.vertical_align = "center"

        -- Find current surface in the surfaces_data or use player's current surface
        local current_surface_data = nil
        local current_surface = game.surfaces[current_surface_index]
        
        for _, data in ipairs(surfaces_data) do
            if data.surface.index == current_surface_index then
                current_surface_data = data
                break
            end
        end
        
        -- If the current surface doesn't have vehicles, we still need surface information
        if not current_surface_data and current_surface then
            current_surface_data = {
                surface = current_surface,
                surface_info = format_surface_name(current_surface.name),
                vehicles = {}
            }
        elseif not current_surface_data and #surfaces_data > 0 then
            -- If current surface not found and no active surface, default to first one
            current_surface_data = surfaces_data[1]
            current_surface_index = current_surface_data.surface.index
            log_debug("Current surface has no vehicles, defaulting to: " .. current_surface_data.surface.name)
        end
        
        -- Add all planet buttons (always show at least the current planet)
        local added_surfaces = {}
        
        -- First add the current surface if it exists
        if current_surface and not added_surfaces[current_surface.index] then
            local planet_name = format_surface_name(current_surface.name).name:lower()
            local sprite_name
            
            -- Known planets that we created sprites for
            local known_planets = {
                ["nauvis"] = true,
                ["aquilo"] = true, 
                ["fulgora"] = true,
                ["gleba"] = true,
                ["vulcanus"] = true
            }
            
            -- Try to use our custom planet sprite if it's a known planet
            if known_planets[planet_name] then
                sprite_name = "vcc-planet-" .. planet_name
            else
                -- For unknown planets, use first letter
                local first_letter = string.sub(planet_name, 1, 1):upper()
                sprite_name = "virtual-signal/signal-" .. first_letter
            end
            
            -- Create planet button for current surface
            planet_button = planet_buttons_flow.add{
                type = "sprite-button",
                sprite = sprite_name,
                tooltip = format_surface_name(current_surface.name).display_name,
                toggled = true,  -- Current surface is always selected
                tags = {
                    action = "quick_select_surface",
                    surface_index = current_surface.index
                }
            }
            planet_button.style.size = 32  -- Adjust size to match sprite
            planet_button.style.margin = 1
            
            -- Mark this surface as added
            added_surfaces[current_surface.index] = true
        end
        
        -- Now add all other surfaces with vehicles
        for _, data in ipairs(surfaces_data) do
            -- Only add each surface once
            if not added_surfaces[data.surface.index] then
                local planet_name = data.surface_info.name:lower()
                local sprite_name
                
                -- Known planets that we created sprites for
                local known_planets = {
                    ["nauvis"] = true,
                    ["aquilo"] = true, 
                    ["fulgora"] = true,
                    ["gleba"] = true,
                    ["vulcanus"] = true
                }
                
                -- Try to use our custom planet sprite if it's a known planet
                if known_planets[planet_name] then
                    sprite_name = "vcc-planet-" .. planet_name
                else
                    -- For unknown planets, use first letter
                    local first_letter = string.sub(planet_name, 1, 1):upper()
                    sprite_name = "virtual-signal/signal-" .. first_letter
                end
                
                -- Create planet button
                local planet_button = planet_buttons_flow.add{
                    type = "sprite-button",
                    sprite = sprite_name,
                    tooltip = data.surface_info.display_name,
                    toggled = data.surface.index == current_surface_index,  -- Toggle on for selected planet
                    tags = {
                        action = "quick_select_surface",
                        surface_index = data.surface.index
                    }
                }
                planet_button.style.size = 32  -- Adjust size to match sprite
                planet_button.style.margin = 1
                
                -- Mark this surface as added
                added_surfaces[data.surface.index] = true
            end
        end

        if next(added_surfaces, next(added_surfaces)) then  -- Check if there are at least 2 surfaces
            -- Add spacer to push the dropdown button to the right
            local spacer = planet_buttons_flow.add{
                type = "empty-widget",
                style = "draggable_space"
            }
            spacer.style.horizontally_stretchable = true
            spacer.style.minimal_width = 10
            spacer.style.natural_height = 30
        
            -- Add dropdown arrow button at the end (right side)
            local dropdown_button = planet_buttons_flow.add{
                type = "sprite-button",
                sprite = "utility/dropdown",
                tooltip = {"vcc.more-surfaces"},
                tags = {
                    action = "surface_selector"
                }
            }
            dropdown_button.style.size = 28
            dropdown_button.style.margin = 1
        end
    end 
    -- Store current surface index in the main frame tags
    main_frame.tags = {
        current_surface_index = current_surface_index,
        vehicle_type = vehicle_type,
        map_view_open = false,
        vehicle_filters = {}
    }

    -- Add a horizontal line to separate planet filters from entity filters
    main_content.add{
        type = "line",
        direction = "horizontal"
    }

    -- Add entity filter section
    local entity_filter_flow = main_content.add{
        type = "flow",
        direction = "horizontal",
        name = "entity_filter_flow"
    }
    entity_filter_flow.style.vertical_align = "center"
    entity_filter_flow.style.margin = {4, 0, 4, 0}

    -- Label for entity filters
    local filter_label = entity_filter_flow.add{
        type = "label",
        caption = {"vcc.filter-vehicles"}
    }
    filter_label.style.minimal_width = 100

    -- Collect all unique vehicle types across all surfaces for the selected vehicle type
    local vehicle_types = {}
    for _, data in ipairs(surfaces_data) do
        for _, vehicle in ipairs(data.vehicles) do
            -- Only include vehicles matching the current type filter
            if vehicle_type == "all" or vehicle.type == vehicle_type then
                if not vehicle_types[vehicle.name] then
                    vehicle_types[vehicle.name] = {
                        name = vehicle.name,
                        count = 1,
                        enabled = true  -- Default to showing all types
                    }
                else
                    vehicle_types[vehicle.name].count = vehicle_types[vehicle.name].count + 1
                end
            end
        end
    end

    -- Update the main frame tags to include vehicle filters
    main_frame.tags.vehicle_filters = vehicle_types

    -- Add filter buttons for each vehicle type
    for name, info in pairs(vehicle_types) do
        -- Check if we have saved filter settings
        local is_enabled = true -- Default state
        if storage.vcc.vehicle_filters and 
           storage.vcc.vehicle_filters[player.index] and
           storage.vcc.vehicle_filters[player.index][name] ~= nil then
            is_enabled = storage.vcc.vehicle_filters[player.index][name]
        end
        
        -- Update the vehicle_types entry
        vehicle_types[name].enabled = is_enabled
        
        -- Use prototype icon if possible
        local vehicle_button = entity_filter_flow.add{
            type = "sprite-button",
            name = "filter_" .. name,
            sprite = "entity/" .. name,
            tooltip = {"entity-name." .. name}, 
            toggled = is_enabled,  -- Use saved state
            tags = {
                action = "toggle_vehicle_filter",
                vehicle_name = name
            }
        }
        vehicle_button.style.size = 28
        vehicle_button.style.margin = 1
    end

    -- Add horizontal separator before vehicle list
    main_content.add{
        type = "line",
        direction = "horizontal"
    }
    
    -- Create scroll pane for vehicles
    local vehicle_list = main_content.add{
        type = "scroll-pane",
        name = "vehicle_list",
        horizontal_scroll_policy = "never",
        vertical_scroll_policy = "auto"
    }
    vehicle_list.style.maximal_height = 300
    vehicle_list.style.minimal_width = 550

    -- Populate the vehicle list if we have vehicle data
    -- Get vehicles from the current surface
    local vehicles = {}
    if current_surface then
        vehicles = get_valid_vehicles_on_surface(current_surface, player.force, vehicle_type or "all")
        log_debug("Found " .. #vehicles .. " vehicles on surface " .. current_surface.name)
    end

    local has_vehicles = false

    -- Make sure vehicles exists before trying to iterate
    if vehicles and #vehicles > 0 then
        for _, vehicle in ipairs(vehicles) do
            local show_vehicle = true
            
            -- Apply name filters if present
            if filters and filters[vehicle.name] == false then
                show_vehicle = false
            end
            
            if show_vehicle then
                has_vehicles = true
                
                local row = vehicle_list.add{
                    type = "flow", 
                    direction = "horizontal",
                    name = "vehicle_" .. vehicle.unit_number
                }
                row.style.vertical_align = "center"
                row.style.top_padding = 2
                row.style.bottom_padding = 2
                
                -- Left side: icon and name
                local entity_icon = row.add{
                    type = "sprite-button",
                    sprite = "entity/" .. vehicle.name,
                    --enabled = false
                }
                entity_icon.style.size = 28
                entity_icon.style.padding = 0
                entity_icon.style.margin = 0
                
                local display_name = get_display_name(vehicle)
                local name_label = row.add{
                    type = "label", 
                    caption = display_name
                }
                name_label.style.minimal_width = 176
                
                -- Add spacer to push buttons to the right
                local spacer = row.add{
                    type = "empty-widget"
                }
                spacer.style.horizontally_stretchable = true
                spacer.style.minimal_width = 10
                
                -- Right side: buttons
                local button_flow = row.add{
                    type = "flow",
                    direction = "horizontal"
                }
                button_flow.style.horizontal_align = "right"
                
                add_buttons_to_vehicle_row(row, vehicle, button_flow)
            end
        end
    end

    -- Show "no vehicles" message if none were displayed
    if not has_vehicles then
        log_debug("No vehicles passed filters - showing empty message")
        vehicle_list.add{
            type = "label",
            caption = {"vcc.no-vehicles-of-type"}
        }
    end

    -- Add horizontal separator after vehicle list
    main_content.add{
        type = "line",
        direction = "horizontal"
    }

    -- Add buttons at the bottom
    local button_flow = main_content.add{
        type = "flow", 
        direction = "horizontal"
    }
    button_flow.style.horizontal_align = "center"
    button_flow.style.top_margin = 8

    
    -- Set player data
    if not storage.vcc.players[player.index] then
        storage.vcc.players[player.index] = {}
    end
    
    storage.vcc.players[player.index].gui_open = true
    storage.vcc.players[player.index].current_surface_index = current_surface_index
    storage.vcc.players[player.index].vehicle_type = vehicle_type
    
    return main_frame
end

-- Function to update the vehicle list based on current surface
function control_center.update_vehicle_type_display(player, vehicle_type)
    log_debug("Updating vehicle type to: " .. vehicle_type)
    
    -- Store the last used vehicle type
    storage.vcc.last_vehicle_type = storage.vcc.last_vehicle_type or {}
    storage.vcc.last_vehicle_type[player.index] = vehicle_type
    
    -- Close the existing GUI if it's open
    if player.gui.screen.vehicle_control_center then
        player.gui.screen.vehicle_control_center.destroy()
    end
    
    -- Get the current main frame
    local main_frame = player.gui.screen.vehicle_control_center
    if not main_frame or not main_frame.valid then
        -- If the frame doesn't exist, create it
        control_center.create_gui(player, vehicle_type)
        return
    end
    
    -- Update the frame's vehicle type
    main_frame.tags.vehicle_type = vehicle_type
    
    -- Update tab button states
    local vehicle_selector_flow = main_frame.main_content.vehicle_selector_flow
    if vehicle_selector_flow then
        for _, child in pairs(vehicle_selector_flow.children) do
            if child.type == "sprite-button" and child.tags and child.tags.action == "select_tab" then
                child.enabled = child.tags.vehicle_type ~= vehicle_type
            end
        end
    end
    
    -- Get current surface index
    local surface_index = main_frame.tags.current_surface_index or player.surface.index
    
    -- Update the surface display with the new vehicle type
    control_center.update_surface_display(player, surface_index)
end

-- Create surface selector dropdown
function control_center.create_surface_dropdown(player)
    -- First check if dropdown already exists and remove it
    if player.gui.screen.surface_selector_dropdown then
        player.gui.screen.surface_selector_dropdown.destroy()
        return
    end
    
    -- Get the current vehicle type from main frame tags
    local main_frame = player.gui.screen.vehicle_control_center
    if not main_frame or not main_frame.valid or not main_frame.tags then
        log_debug("Main frame not found when creating dropdown")
        return
    end
    
    local vehicle_type = main_frame.tags.vehicle_type or "all"
    local surfaces_data = collect_surfaces_with_vehicles(player.force, vehicle_type)
    
    if #surfaces_data == 0 then
        return
    end
    
    -- Create dropdown frame
    local dropdown_frame = player.gui.screen.add{
        type = "frame",
        name = "surface_selector_dropdown",
        direction = "vertical",
        style = "inside_shallow_frame"
    }

    -- Position the dropdown at a fixed location relative to the main frame
    dropdown_frame.location = {
        x = main_frame.location.x + 200, 
        y = main_frame.location.y + 100
    }
    
    -- Create scroll pane for surfaces
    local surface_list = dropdown_frame.add{
        type = "scroll-pane",
        name = "surface_list",
        horizontal_scroll_policy = "never",
        vertical_scroll_policy = "auto"
    }
    surface_list.style.maximal_height = 300
    surface_list.style.minimal_width = 200 
    surface_list.style.padding = {2, 2}
    
    -- Add surfaces to dropdown (prevent duplicates)
    local added_surfaces = {}
    
    for _, data in ipairs(surfaces_data) do
        -- Only add each surface once
        if not added_surfaces[data.surface.index] then
            local surface_button = surface_list.add{
                type = "button",
                caption = data.surface_info.formatted or data.surface.name,
                tooltip = data.surface.name,
                tags = {
                    action = "select_surface",
                    surface_index = data.surface.index
                }
            }
            surface_button.style.minimal_width = 190
            surface_button.style.horizontal_align = "left"
            
            -- Mark this surface as added
            added_surfaces[data.surface.index] = true
        end
    end
end

-- Function to update surface display when a new surface is selected
function control_center.update_surface_display(player, surface_index)
    local main_frame = player.gui.screen.vehicle_control_center
    if not main_frame or not main_frame.valid then 
        log_debug("Main frame not found when updating surface")
        return 
    end
    
    local main_content = main_frame.main_content
    if not main_content then
        log_debug("Main content not found")
        return
    end
    
    local vehicle_list = main_content.vehicle_list
    if not vehicle_list then
        log_debug("Vehicle list not found")
        return
    end
    
    local surface = game.surfaces[surface_index]
    if not surface then
        log_debug("Selected surface doesn't exist anymore")
        return
    end
    
    -- Update the surface index in the frame tags
    main_frame.tags = main_frame.tags or {}
    main_frame.tags.current_surface_index = surface_index
    
    -- Update planet buttons to reflect the new selection
    local planet_buttons_flow = main_content.surface_selector_flow.planet_buttons_flow
    if planet_buttons_flow then
        for _, button in pairs(planet_buttons_flow.children) do
            if button.type == "sprite-button" and button.tags and button.tags.action == "quick_select_surface" then
                button.toggled = (button.tags.surface_index == surface_index)
            end
        end
    end
    
    -- Get vehicle filters
    local filters = {}
    local entity_filter_flow = main_content.entity_filter_flow
    if entity_filter_flow then
        for _, child in pairs(entity_filter_flow.children) do
            if child.type == "sprite-button" and child.name and child.name:find("^filter_") then
                local vehicle_name = child.name:sub(8)
                filters[vehicle_name] = child.toggled
                log_debug("Filter for " .. vehicle_name .. ": " .. tostring(child.toggled))
            end
        end
    end
    
    -- Clear and repopulate the vehicle list with the selected surface's vehicles
    vehicle_list.clear()
    
    local vehicles = get_valid_vehicles_on_surface(surface, player.force, main_frame.tags.vehicle_type or "all")
    log_debug("Found " .. #vehicles .. " vehicles on surface " .. surface.name)
    
    local has_vehicles = false

    for _, vehicle in ipairs(vehicles) do
        local show_vehicle = true
        
        -- Apply name filters if present
        if filters[vehicle.name] == false then
            show_vehicle = false
        end
        
        if show_vehicle then
            has_vehicles = true
            
            local row = vehicle_list.add{
                type = "flow", 
                direction = "horizontal",
                name = "vehicle_" .. vehicle.unit_number
            }
            row.style.vertical_align = "center"
            row.style.top_padding = 2
            row.style.bottom_padding = 2
            row.style.horizontal_align = "left" -- This spaces items evenly
            
            -- Create left side container for icon and name
            local left_container = row.add{
                type = "flow",
                direction = "horizontal"
            }
            left_container.style.vertical_align = "center"
            
            -- Add entity icon to left container
            local entity_icon = left_container.add{
                type = "sprite-button",
                sprite = "entity/" .. vehicle.name,
            }
            entity_icon.style.size = 28
            entity_icon.style.padding = 0
            entity_icon.style.margin = 0
            
            -- Add name label to left container
            local display_name = get_display_name(vehicle)
            local name_label = left_container.add{
                type = "label", 
                caption = display_name
            }
            name_label.style.minimal_width = 176
            
            -- Create right side container for buttons
            local button_flow = row.add{
                type = "flow",
                direction = "horizontal"
            }
            button_flow.style.vertical_align = "center"
            button_flow.style.horizontal_align = "right"
            
            -- Add buttons to right container
            add_buttons_to_vehicle_row(row, vehicle, button_flow)
        end
    end
    
    -- Show "no vehicles" message if none were displayed
    if not has_vehicles then
        log_debug("No vehicles passed filters - showing empty message")
        vehicle_list.add{
            type = "label",
            caption = {"vcc.no-vehicles-of-type"}
        }
    end
    
    -- Close dropdown if open
    if player.gui.screen.surface_selector_dropdown then
        player.gui.screen.surface_selector_dropdown.destroy()
    end
    
    -- Store the surface selection for future use
    storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
    storage.vcc.players[player.index].current_surface_index = surface_index
end

-- Toggle visibility of the GUI
function control_center.toggle_gui(player)
    if not player or not player.valid then return end
    
    -- Initialize player data if it doesn't exist yet
    storage.vcc = storage.vcc or {}
    storage.vcc.players = storage.vcc.players or {}
    storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
    
    local player_data = storage.vcc.players[player.index]
    
    if player_data.gui_open then
        control_center.close_gui(player)
    else
        control_center.open_gui(player)
    end
end

-- Open the GUI
function control_center.open_gui(player)
    -- Make sure storage exists
    storage.vcc.last_vehicle_type = storage.vcc.last_vehicle_type or {}
    
    -- Get player data
    local player_data = storage.vcc.players[player.index]
    
    -- Get last selected type or default to "spider-vehicle" for first time
    local last_type
    if storage.vcc.last_vehicle_type[player.index] then
        last_type = storage.vcc.last_vehicle_type[player.index]
    else
        -- Default to spidertron for first open
        last_type = "spider-vehicle"
        storage.vcc.last_vehicle_type[player.index] = last_type
    end
    
    -- Create the GUI with last settings
    control_center.create_gui(player, last_type)
end

-- Close the GUI
function control_center.close_gui(player)
    if not player or not player.valid then return end
    
    -- Close map view if open
    local player_data = storage.vcc.players[player.index]
    if player_data and player_data.map_view_open then
        player.close_map()
        player_data.map_view_open = false
    end
    
    -- Close dropdown if open
    if player.gui.screen.surface_selector_dropdown then
        player.gui.screen.surface_selector_dropdown.destroy()
    end
    
    -- Close main frame
    if player.gui.screen.vehicle_control_center then
        player.gui.screen.vehicle_control_center.destroy()
    end
    
    -- Update player data
    if player_data then
        player_data.gui_open = false
    end
end

function control_center.register_events()
    -- Register ESC key event handler (on_gui_closed)
    script.on_event(defines.events.on_gui_closed, function(event)
        local player = game.get_player(event.player_index)
        if player and player.gui.screen.vehicle_control_center then
            control_center.close_gui(player)
        end
    end)
end

-- Connect to a vehicle using Neural Spider Control
function control_center.connect_to_vehicle(player, unit_number, surface_index)
    log_debug("Attempting to connect to vehicle #" .. unit_number)
    
    local surface = game.surfaces[surface_index]
    if not surface then return end
    
    -- Find the vehicle
    local vehicle = nil
    for _, entity in pairs(surface.find_entities_filtered{type = {"spider-vehicle", "car", "locomotive"}}) do
        if entity.unit_number == unit_number then
            vehicle = entity
            break
        end
    end
    
    if not vehicle or not vehicle.valid then
        --player.print({"vcc-gui.vehicle-not-found"})
        return
    end
    
    -- If Neural Spider Control mod is active, use it
    if script.active_mods["neural-spider-control"] then
        -- Close the control center GUI
        if player.gui.screen.vehicle_control_centre then
            player.gui.screen.vehicle_control_centre.destroy()
        end
        
        -- Call the connect function directly
        --local neural_connect = require("__neural-spider-control__.scripts.neural_connect")
        if neural_connect and neural_connect.connect_to_spidertron then
            neural_connect.connect_to_spidertron({
                player_index = player.index,
                spidertron = vehicle
            })
        else
            --player.print({"vcc-gui.connect-failed"})
        end
    else
        --player.print({"vcc-gui.neural-mod-not-installed"})
    end
end

-- Handle GUI click events
function control_center.on_gui_click(event)
    if not event.element or not event.element.valid then return end
    
    local player = game.get_player(event.player_index)
    local element = event.element
    
    log_debug("GUI click on element: " .. element.name)
    
    -- Extract tags
    local action = element.tags and element.tags.action
    
    -- Top button to open/close control center
    if element.name == "vcc_button" then
        control_center.toggle_gui(player)
        return
    end
    
    -- Close buttons
    if element.name == "vcc_close_button" or element.name == "close_vehicle_control_center" then
        control_center.close_gui(player)
        return
    end
    
    -- Refresh button
    if element.name == "vcc_refresh_button" then
        if scan_vehicles_function then
            scan_vehicles_function()
        end
        
        -- Refresh GUI with current settings
        local main_frame = player.gui.screen.vehicle_control_center
        if main_frame and main_frame.tags then
            local vehicle_type = main_frame.tags.vehicle_type or "all"
            control_center.create_gui(player, vehicle_type)
        end
        return
    end
    
    -- Handle actions based on tags
    if action then
        -- Surface selector
-- Surface selection (from dropdown)
        if action == "select_surface" then
            local surface_index = element.tags.surface_index
            
            -- Store surface selection
            storage.vcc.players[player.index] = storage.vcc.players[player.index] or {}
            storage.vcc.players[player.index].current_surface_index = surface_index
            
            -- Close dropdown
            if player.gui.screen.surface_selector_dropdown then
                player.gui.screen.surface_selector_dropdown.destroy()
            end
            
            -- Get current vehicle type and recreate GUI
            local vehicle_type = storage.vcc.last_vehicle_type[player.index] or "all"
            if player.gui.screen.vehicle_control_center then
                if player.gui.screen.vehicle_control_center.tags then
                    vehicle_type = player.gui.screen.vehicle_control_center.tags.vehicle_type or vehicle_type
                end
                player.gui.screen.vehicle_control_center.destroy()
            end
            
            -- Recreate GUI with new surface
            control_center.create_gui(player, vehicle_type)
            return
        end

        -- Quick surface selection
        if action == "quick_select_surface" then
            local surface_index = element.tags.surface_index
            control_center.update_surface_display(player, surface_index)
            return
        end

        if event.element.name == "back_to_deployment_btn" then
            -- Close the extras menu
            if player.gui.screen["spidertron_extras_frame"] then
                player.gui.screen["spidertron_extras_frame"].destroy()
            end
            
            -- Retrieve stored vehicle data
            local vehicle_data = storage.temp_deployment_data.vehicle
            
            -- Reopen the deployment menu with the same vehicles list
            map_gui.show_deployment_menu(player, {vehicle_data})
        end

        -- Vehicle filter toggle
        if action == "toggle_vehicle_filter" then
            local vehicle_name = element.tags.vehicle_name
            
            -- Toggle and save filter state
            storage.vcc.vehicle_filters = storage.vcc.vehicle_filters or {}
            storage.vcc.vehicle_filters[player.index] = storage.vcc.vehicle_filters[player.index] or {}
            
            local current_state = storage.vcc.vehicle_filters[player.index][vehicle_name]
            if current_state == nil then 
                current_state = true -- Default to showing
            end
            
            storage.vcc.vehicle_filters[player.index][vehicle_name] = not current_state
            
            -- Get current vehicle type and surface
            local vehicle_type = storage.vcc.last_vehicle_type[player.index] or "all"
            if player.gui.screen.vehicle_control_center then
                if player.gui.screen.vehicle_control_center.tags then
                    vehicle_type = player.gui.screen.vehicle_control_center.tags.vehicle_type or vehicle_type
                end
                player.gui.screen.vehicle_control_center.destroy()
            end
            
            -- Recreate GUI with updated filters
            control_center.create_gui(player, vehicle_type)
            return
        end
    end
    
    -- Pass to control center
    if control_center.on_gui_click then
        control_center.on_gui_click(event)
    end
end

-- Handle when player clicks elsewhere to close dropdown
function control_center.on_player_cursor_stack_changed(event)
    local player = game.get_player(event.player_index)
    -- Close surface dropdown if it's open
    if player.gui.screen.surface_selector_dropdown then
        player.gui.screen.surface_selector_dropdown.destroy()
    end
end

-- Return the module
return control_center