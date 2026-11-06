-- Check if advisories exist and have correlations
SELECT 
  p."Id",
  p."PsirtId", 
  COUNT(d."Id") as correlation_count,
  array_agg(DISTINCT d."CorrelationStatus") as statuses
FROM "PsirtAdvisories" p 
LEFT JOIN "DevicePsirts" d ON p."Id" = d."PsirtAdvisoryId"
WHERE p."PsirtId" IN ('FG-IR-26-060', 'FG-IR-25-647')
GROUP BY p."Id", p."PsirtId"
ORDER BY p."PsirtId";
