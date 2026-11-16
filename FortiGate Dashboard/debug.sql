-- Check firmware versions of devices
SELECT "FirmwareVersion", COUNT(*) as device_count
FROM "Devices"
GROUP BY "FirmwareVersion"
ORDER BY device_count DESC;

-- Check if any specific device has a firmware that should match 7.4.0 through 7.4.7
SELECT "Name", "SerialNumber", "FirmwareVersion"
FROM "Devices"
WHERE "FirmwareVersion" LIKE '7.4.%'
LIMIT 10;
