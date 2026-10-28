local BasePowerD = require("device/generic/powerd")
local bb10 = require("ffi/bb10")

local BB10PowerD = BasePowerD:new{}

function BB10PowerD:frontlightIntensityHW()
    return 0
end

function BB10PowerD:setIntensityHW(intensity) -- luacheck: ignore
end

function BB10PowerD:getCapacityHW()
    local capacity = bb10.getBatteryInfo()
    return capacity or 0
end

function BB10PowerD:isChargingHW()
    local _, charging = bb10.getBatteryInfo()
    return charging or false
end

return BB10PowerD
