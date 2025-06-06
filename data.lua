-- data.lua for Vehicle Control Center

-- Add hotkey for toggling the GUI
data:extend({
    {
        type = "custom-input",
        name = "vcc-toggle",
        key_sequence = "ALT + V",
        consuming = "none"
    }
})

-- Add shortcut to open the GUI
data:extend({
    {
        type = "shortcut",
        name = "vcc-toggle",
        order = "v[eh]-[a]",
        action = "lua",
        localised_name = {"controls.shortcut-toggle"},
        associated_control_input = "vcc-toggle",
        icon = "__vehicle-control-center__/graphics/icons/vcc.png",
        small_icon = "__vehicle-control-center__/graphics/icons/vcc.png"
    }
})

data:extend({
    {
      type = "sprite",
      name = "neural-connection-sprite",
      filename = "__vehicle-control-center__/graphics/icons/vcc.png",
      priority = "extra-high",
      width = 64,
      height = 64
    }
})

data:extend({
    {
      type = "sprite",
      name = "vcc-map",
      filename = "__vehicle-control-center__/graphics/icons/vcc-map.png",
      priority = "extra-high",
      width = 64,
      height = 64
    }
})

data:extend({
    {
      type = "sprite",
      name = "vcc-whistle",
      filename = "__vehicle-control-center__/graphics/icons/vcc-whistle.png",
      priority = "extra-high",
      width = 64,
      height = 64
    }
})

data:extend({
    {
      type = "sprite",
      name = "vcc-wifi",
      filename = "__vehicle-control-center__/graphics/icons/vcc-wifi.png",
      priority = "extra-high",
      width = 64,
      height = 64
    }
})




local function create_planet_sprites()
    -- Check if Space Age mod is installed
    local space_age_present = mods["space-age"]
    
    if not space_age_present then
        log("Space Age not detected, using default planet sprites")
        return
    end
    
    log("Space Age detected, creating planet sprites")
    
    -- List of known planets from Space Age
    local planet_list = {
        --"nauvis",
        "aquilo", 
        "fulgora", 
        "gleba", 
        "vulcanus"
    }
    
    -- Create sprites for each planet
    for _, planet_name in pairs(planet_list) do
        -- Path to the planet image in Space Age
        local image_path = "__space-age__/graphics/icons/starmap-planet-" .. planet_name .. ".png"
        
        -- Create a sprite definition
        data:extend({
            {
                type = "sprite",
                name = "vcc-planet-" .. planet_name,
                filename = image_path,
                priority = "medium",
                width = 512,
                height = 512,
            }
        })
        
        log("Created sprite for planet: " .. planet_name)
    end
end

create_planet_sprites()

local function create_nauvis_sprite()
    
    local planet_list = {
        "nauvis"
    }
    
    -- Create sprites for each planet
    for _, planet_name in pairs(planet_list) do
        -- Path to the planet image in Space Age
        local image_path = "__base__/graphics/icons/starmap-planet-nauvis.png"
        
        -- Create a sprite definition
        data:extend({
            {
                type = "sprite",
                name = "vcc-planet-" .. planet_name,
                filename = image_path,
                priority = "medium",
                width = 512,
                height = 512,
            }
        })
        
        log("Created sprite for planet: " .. planet_name)
    end
end

create_nauvis_sprite()
