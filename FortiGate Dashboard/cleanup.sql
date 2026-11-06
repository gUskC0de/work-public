-- Delete correlations for non-FortiGate products
DELETE FROM "DevicePsirts" dp
WHERE EXISTS (
  SELECT 1 FROM "PsirtAdvisories" pa
  WHERE pa."Id" = dp."PsirtAdvisoryId"
  AND (
    LOWER(pa."Title") LIKE '%fortipam%' OR
    LOWER(pa."Title") LIKE '%fortiproxy%' OR
    LOWER(pa."Title") LIKE '%fortimail%' OR
    LOWER(pa."Title") LIKE '%chrome extension%' OR
    LOWER(pa."Title") LIKE '%forticlient%' OR
    LOWER(pa."Title") LIKE '%fortianalyz%' OR
    LOWER(pa."Title") LIKE '%fortimanager%' OR
    LOWER(pa."Title") LIKE '%fortiedr%'
  )
);

-- Show final counts
SELECT "CorrelationStatus", COUNT(*) FROM "DevicePsirts" GROUP BY "CorrelationStatus";

-- Show which advisories were removed
SELECT pa."PsirtId", pa."Title" FROM "PsirtAdvisories" pa
WHERE 
  LOWER(pa."Title") LIKE '%fortipam%' OR
  LOWER(pa."Title") LIKE '%fortiproxy%' OR
  LOWER(pa."Title") LIKE '%fortimail%' OR
  LOWER(pa."Title") LIKE '%chrome extension%'
ORDER BY pa."PsirtId";
