# The maps of the reference zones (make-zone-saves.ps1) and of the next departure from a reference garage
# (start-zone.ps1 -StopInGarage with COOPTEST_QUICKSTART=1): fixed, so a test always drives to the same map.
$ZoneMap = @{
    host   = '/Game/Maps/Wilderness/MapLocations/Forest/MLoc_Wilderness_Forest_15.MLoc_Wilderness_Forest_15'
    client = '/Game/Maps/Wilderness/MapLocations/Forest/MLoc_Wilderness_Forest_05.MLoc_Wilderness_Forest_05'
}
$ZoneSeed = @{ host = 12345; client = 999 }
