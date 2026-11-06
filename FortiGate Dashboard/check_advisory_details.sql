-- Check advisory details
SELECT 
  "PsirtId",
  "Title",
  "AffectedVersionRange",
  "ParseStatus",
  "Severity"
FROM "PsirtAdvisories" 
WHERE "PsirtId" IN ('FG-IR-26-060', 'FG-IR-25-647')
ORDER BY "PsirtId";

-- Check some known devices
SELECT 
  "Name",
  "FirmwareVersion",
  "Hostname"
FROM "Devices"
WHERE "FirmwareVersion" NOT IN ('Unknown', '')
ORDER BY "FirmwareVersion" DESC
LIMIT 15;
