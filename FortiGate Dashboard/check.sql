-- Check for non-FortiGate advisories that are still in the database
SELECT "PsirtId", "Title" FROM "PsirtAdvisories"
WHERE 
  LOWER("Title") LIKE '%fortipam%' OR
  LOWER("Title") LIKE '%fortiproxy%' OR
  LOWER("Title") LIKE '%fortimail%' OR
  LOWER("Title") LIKE '%chrome extension%'
ORDER BY "PsirtId";

-- Show correlation status distribution
SELECT "CorrelationStatus", COUNT(*) FROM "DevicePsirts" GROUP BY "CorrelationStatus";

-- Show which advisories have uncertain correlations
SELECT pa."PsirtId", pa."Title", COUNT(dp."Id") as count FROM "PsirtAdvisories" pa
JOIN "DevicePsirts" dp ON pa."Id" = dp."PsirtAdvisoryId"
WHERE dp."CorrelationStatus" = 3
GROUP BY pa."Id", pa."PsirtId", pa."Title"
ORDER BY count DESC LIMIT 10;
