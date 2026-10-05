-- Named header-first report projections keep full reports out of ordinary reads.
-- name: OwnerToolNext :many
SELECT CASE WHEN typeof(address) = 'text' AND length(CAST(address AS BLOB)) <= 8192 THEN address ELSE '' END AS address
FROM owner_custody_tools WHERE address > @after_address ORDER BY address LIMIT 1;

-- name: OwnerReportIdentity :many
SELECT address, identity FROM owner_custody_tools
WHERE result_entry = @result_entry AND typeof(address) = 'text' AND length(CAST(address AS BLOB)) <= 8192
  AND typeof(identity) = 'blob' AND length(identity) <= 8192 LIMIT 2;

-- name: OwnerToolIdentity :many
SELECT identity FROM owner_custody_tools WHERE address = @address
  AND typeof(identity) = 'blob' AND length(identity) <= 8192 LIMIT 2;

-- name: OwnerReportValue :many
SELECT report FROM owner_custody_tools WHERE address = @address
  AND final_profile = 'code_mode_report_v1' AND final_allowance = 17301648
  AND typeof(report) = 'blob' AND length(report) BETWEEN 18 AND 17039376
  AND typeof(report_digest) = 'text' AND length(CAST(report_digest AS BLOB)) = 64 LIMIT 2;

-- name: RetainOwnerReport :exec
UPDATE owner_custody_tools SET report = @report, report_digest = @report_digest
WHERE address = @address AND state = 'retained' AND final_profile = 'code_mode_report_v1'
  AND final_allowance = 17301648 AND report IS NULL AND outcome IS NULL;

-- name: OwnerReportChunk :many
SELECT CAST(substr(report, CAST(@byte_offset AS INTEGER) + 1, 65536) AS BLOB) AS chunk
FROM owner_custody_tools WHERE address = @address
  AND final_profile = 'code_mode_report_v1' AND final_allowance = 17301648
  AND typeof(report) = 'blob' AND length(report) = CAST(@report_bytes AS INTEGER)
  AND length(report) BETWEEN 18 AND 17039376 AND report_digest = @report_digest
  AND (state = 'frozen' OR outcome IS NOT NULL) LIMIT 2;
