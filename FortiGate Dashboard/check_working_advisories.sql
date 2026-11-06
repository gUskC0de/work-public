SELECT p."PsirtId", COUNT(d."Id") as correlation_count, p."AffectedVersionRange"
FROM "PsirtAdvisories" p
LEFT JOIN "DevicePsirts" d ON p."Id" = d."PsirtAdvisoryId"
GROUP BY p."Id", p."PsirtId", p."AffectedVersionRange"
HAVING COUNT(d."Id") > 0
ORDER BY correlation_count DESC;
