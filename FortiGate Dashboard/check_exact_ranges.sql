-- Get the exact affected version ranges
SELECT 
  "PsirtId",
  "AffectedVersionRange",
  length("AffectedVersionRange") as length_chars
FROM "PsirtAdvisories" 
WHERE "PsirtId" IN ('FG-IR-26-060', 'FG-IR-25-647')
ORDER BY "PsirtId";
