-- Check all firmware versions and their counts
SELECT 
  "FirmwareVersion",
  COUNT(*) as device_count
FROM "Devices"
WHERE "FirmwareVersion" NOT IN ('Unknown', '')
GROUP BY "FirmwareVersion"
ORDER BY "FirmwareVersion";
