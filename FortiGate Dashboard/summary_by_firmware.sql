-- Summary of PSIRT correlations by firmware version
SELECT 
  dev."FirmwareVersion",
  COUNT(DISTINCT dev."Id") as device_count,
  COUNT(DISTINCT CASE WHEN p."PsirtId" = 'FG-IR-26-060' THEN d."Id" END) as "FG-IR-26-060",
  COUNT(DISTINCT CASE WHEN p."PsirtId" = 'FG-IR-25-647' THEN d."Id" END) as "FG-IR-25-647"
FROM "Devices" dev
LEFT JOIN "DevicePsirts" d ON dev."Id" = d."DeviceId"
LEFT JOIN "PsirtAdvisories" p ON d."PsirtAdvisoryId" = p."Id"
WHERE dev."FirmwareVersion" NOT IN ('Unknown', '')
GROUP BY dev."FirmwareVersion"
ORDER BY dev."FirmwareVersion";
