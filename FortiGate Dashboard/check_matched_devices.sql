-- Check which devices are matched to each advisory
SELECT p."PsirtId", d."DeviceId", dev."FirmwareVersion", d."CorrelationStatus"
FROM "DevicePsirts" d
JOIN "PsirtAdvisories" p ON d."PsirtAdvisoryId" = p."Id"
JOIN "Devices" dev ON d."DeviceId" = dev."Id"
WHERE p."PsirtId" IN ('FG-IR-26-060', 'FG-IR-25-647')
ORDER BY p."PsirtId", dev."FirmwareVersion";
