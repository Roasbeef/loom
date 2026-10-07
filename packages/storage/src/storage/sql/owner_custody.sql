-- name: OwnerCustodyMetadata :many
SELECT CASE WHEN length(CAST(session_id AS BLOB)) = 36 THEN session_id ELSE '' END AS session_id,
  tool_limit, child_limit, byte_limit, payload_limit FROM owner_custody_meta LIMIT 2;

-- name: InitializeOwnerCustody :exec
INSERT INTO owner_custody_meta(singleton, session_id, tool_limit, child_limit, byte_limit, payload_limit)
VALUES (1, @session_id, @tool_limit, @child_limit, @byte_limit, @payload_limit);

-- name: OwnerCustodyBudget :one
SELECT CAST((SELECT COUNT(*) FROM owner_custody_tools) AS INTEGER) AS tools,
  CAST((SELECT COUNT(*) FROM owner_custody_children) + (SELECT COUNT(*) FROM owner_system_intent WHERE child_address IS NULL) AS INTEGER) AS children,
  CAST((SELECT COUNT(*) FROM owner_custody_command_offers) AS INTEGER) AS offers,
  CAST(COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_tools), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_children), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_command_offers), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_enrollment), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_generation_associations), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_generation_closes), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_tool_generation), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_child_generation), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_system_intent), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_system_ordinal), 0)
    AS INTEGER) AS bytes;

-- name: OwnerToolHeader :many
SELECT CAST(CASE WHEN typeof(identity) = 'blob' THEN length(identity) ELSE -1 END AS INTEGER) AS identity_bytes, CAST(CASE WHEN typeof(arguments) = 'blob' THEN length(arguments) ELSE -1 END AS INTEGER) AS argument_bytes,
  CAST(CASE WHEN typeof(request) = 'blob' THEN length(request) ELSE -1 END AS INTEGER) AS request_bytes, CAST(CASE WHEN outcome IS NULL THEN 0 WHEN typeof(outcome) = 'blob' THEN length(outcome) ELSE -1 END AS INTEGER) AS outcome_bytes,
  CASE WHEN state IN ('retained', 'frozen') THEN state ELSE '' END AS state,
  CASE WHEN run_custody IN ('unreleased', 'released') THEN run_custody ELSE '' END AS run_custody,
  CASE WHEN final_profile IN ('ordinary', 'code_mode_report_v1') THEN final_profile ELSE '' END AS final_profile,
  CAST(CASE WHEN typeof(final_allowance) = 'integer' THEN final_allowance ELSE -1 END AS INTEGER) AS final_allowance,
  CAST(CASE WHEN report IS NULL THEN 0 WHEN typeof(report) = 'blob' AND length(report) >= 18 THEN length(report) ELSE -1 END AS INTEGER) AS report_bytes,
  CASE WHEN report_digest IS NULL THEN '' WHEN typeof(report_digest) = 'text' AND length(CAST(report_digest AS BLOB)) = 64 THEN report_digest ELSE 'invalid' END AS report_digest,
  CASE WHEN typeof(result_entry) = 'text' AND length(CAST(result_entry AS BLOB)) = 36 THEN result_entry ELSE '' END AS result_entry,
  reserved_bytes FROM owner_custody_tools WHERE address = @address LIMIT 2;

-- name: OwnerToolValue :many
SELECT identity, arguments, request, outcome FROM owner_custody_tools
WHERE address = @address AND typeof(identity) = 'blob' AND length(identity) <= 8192
  AND typeof(arguments) = 'blob' AND typeof(request) = 'blob' AND length(arguments) <= CAST(@payload_limit AS INTEGER) AND length(request) <= CAST(@payload_limit AS INTEGER)
  AND (outcome IS NULL OR (typeof(outcome) = 'blob' AND length(outcome) <= CASE WHEN final_profile = 'code_mode_report_v1' THEN 262144 ELSE CAST(@payload_limit AS INTEGER) END)) LIMIT 2;

-- name: InsertOwnerTool :exec
INSERT INTO owner_custody_tools(address, identity, result_entry, arguments, request, final_profile, final_allowance, state, run_custody, reserved_bytes)
VALUES (@address, @identity, @result_entry, @arguments, @request, @final_profile, @final_allowance, 'retained', 'unreleased', @reserved_bytes);

-- name: FinishOwnerTool :exec
UPDATE owner_custody_tools SET outcome = @outcome WHERE address = @address AND state = 'retained' AND outcome IS NULL;

-- name: FreezeOwnerTool :exec
UPDATE owner_custody_tools SET arguments = X'', request = X'', outcome = NULL, state = 'frozen',
  reserved_bytes = length(identity) + length(CAST(address AS BLOB)) + 128
    + CASE WHEN report IS NULL THEN 0 ELSE length(report) + 128 END WHERE address = @address;

-- name: OwnerChildHeader :many
SELECT CASE WHEN length(CAST(request_id AS BLOB)) = 36 THEN request_id ELSE '' END AS request_id,
  CAST(CASE WHEN typeof(request) = 'blob' THEN length(request) ELSE -1 END AS INTEGER) AS request_bytes, CAST(CASE WHEN terminal IS NULL THEN 0 WHEN typeof(terminal) = 'blob' THEN length(terminal) ELSE -1 END AS INTEGER) AS terminal_bytes,
  CASE WHEN state IN ('retained', 'frozen', 'cancelled') THEN state ELSE '' END AS state,
  reserved_bytes FROM owner_custody_children WHERE origin = @origin LIMIT 2;

-- name: OwnerChildValue :many
SELECT request, terminal FROM owner_custody_children WHERE origin = @origin
  AND typeof(request) = 'blob' AND length(request) <= CAST(@payload_limit AS INTEGER) AND (terminal IS NULL OR (typeof(terminal) = 'blob' AND length(terminal) <= CAST(@payload_limit AS INTEGER))) LIMIT 2;

-- name: OwnerChildCount :one
SELECT CAST(COUNT(*) AS INTEGER) AS children FROM owner_custody_children WHERE parent = @parent;

-- name: InsertOwnerChild :exec
INSERT INTO owner_custody_children(origin, parent, request_id, request, state, reserved_bytes)
VALUES (@origin, @parent, @request_id, @request, 'retained', @reserved_bytes);

-- name: FinishOwnerChild :exec
UPDATE owner_custody_children SET terminal = @terminal WHERE origin = @origin AND terminal IS NULL AND state IN ('retained', 'cancelled');

-- name: FreezeOwnerChildren :exec
UPDATE owner_custody_children SET request = X'', terminal = NULL, state = 'frozen',
  reserved_bytes = length(CAST(origin AS BLOB)) + length(CAST(parent AS BLOB)) + 164 WHERE parent = @parent;

-- name: CancelOwnerChild :exec
INSERT INTO owner_custody_children(origin, parent, request_id, request, state, reserved_bytes)
VALUES (@origin, @parent, NULL, X'', 'cancelled', @reserved_bytes)
ON CONFLICT(origin) DO UPDATE SET state = CASE WHEN state = 'frozen' THEN 'frozen' ELSE 'cancelled' END;


-- name: OwnerLegacyCustodyBudget :one
SELECT CAST((SELECT COUNT(*) FROM owner_custody_tools) AS INTEGER) AS tools,
  CAST((SELECT COUNT(*) FROM owner_custody_children) AS INTEGER) AS children,
  CAST(COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_tools), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_children), 0) AS INTEGER) AS bytes;

-- name: OwnerLegacyInvalidHeaders :one
SELECT CAST(
  (SELECT COUNT(*) FROM owner_custody_tools WHERE
    typeof(address) != 'text' OR length(CAST(address AS BLOB)) > 8192
    OR typeof(identity) != 'blob' OR length(identity) > 8192
    OR typeof(arguments) != 'blob' OR length(arguments) > CAST(@payload_limit AS INTEGER)
    OR typeof(request) != 'blob' OR length(request) > CAST(@payload_limit AS INTEGER)
    OR (outcome IS NOT NULL AND (typeof(outcome) != 'blob' OR length(outcome) > CAST(@payload_limit AS INTEGER)))
    OR state NOT IN ('retained', 'frozen') OR typeof(reserved_bytes) != 'integer'
    OR reserved_bytes < length(identity) + length(CAST(address AS BLOB)) + 128
      + CASE WHEN state = 'frozen' THEN 0 ELSE length(arguments) + length(request) + CAST(@payload_limit AS INTEGER) END)
  + (SELECT COUNT(*) FROM owner_custody_children WHERE
    typeof(origin) != 'text' OR length(CAST(origin AS BLOB)) > 8192
    OR typeof(parent) != 'text' OR length(CAST(parent AS BLOB)) > 8192
    OR (request_id IS NULL AND (state NOT IN ('cancelled', 'frozen') OR length(request) != 0 OR terminal IS NOT NULL))
    OR (request_id IS NOT NULL AND (typeof(request_id) != 'text' OR length(CAST(request_id AS BLOB)) != 36))
    OR typeof(request) != 'blob' OR length(request) > CAST(@payload_limit AS INTEGER)
    OR (terminal IS NOT NULL AND (typeof(terminal) != 'blob' OR length(terminal) > CAST(@payload_limit AS INTEGER)))
    OR state NOT IN ('retained', 'cancelled', 'frozen') OR typeof(reserved_bytes) != 'integer'
    OR reserved_bytes < length(CAST(origin AS BLOB)) + length(CAST(parent AS BLOB)) + 164
      + CASE WHEN state = 'frozen' THEN 0 ELSE length(request) + CASE WHEN request_id IS NULL THEN 0 ELSE CAST(@payload_limit AS INTEGER) END END)
  AS INTEGER) AS invalid;

-- name: OwnerCommandOfferHeader :many
SELECT
  CASE WHEN typeof(parent) = 'text' AND length(CAST(parent AS BLOB)) <= 8192 THEN parent ELSE '' END AS parent,
  CASE WHEN typeof(service_origin) = 'text' AND length(CAST(service_origin AS BLOB)) <= 8192 THEN service_origin ELSE '' END AS service_origin,
  CASE WHEN typeof(service_id) = 'text' AND length(CAST(service_id AS BLOB)) = 36 THEN service_id ELSE '' END AS service_id,
  CASE WHEN typeof(native_origin) = 'text' AND length(CAST(native_origin AS BLOB)) <= 8192 THEN native_origin ELSE '' END AS native_origin,
  CASE WHEN typeof(offer_digest) = 'text' AND length(CAST(offer_digest AS BLOB)) = 64 THEN offer_digest ELSE '' END AS offer_digest,
  CAST(CASE WHEN typeof(identity) = 'blob' THEN length(identity) ELSE -1 END AS INTEGER) AS identity_bytes,
  CAST(CASE WHEN typeof(offer) = 'blob' THEN length(offer) ELSE -1 END AS INTEGER) AS offer_bytes,
  CASE WHEN state IN ('retained', 'cancelled', 'frozen') THEN state ELSE '' END AS state,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes
  FROM owner_custody_command_offers WHERE address = @address LIMIT 2;

-- name: OwnerCommandOfferHeaderByNativeOrigin :many
SELECT
  CASE WHEN typeof(address) = 'text' AND length(CAST(address AS BLOB)) <= 8192 THEN address ELSE '' END AS address,
  CASE WHEN typeof(parent) = 'text' AND length(CAST(parent AS BLOB)) <= 8192 THEN parent ELSE '' END AS parent,
  CASE WHEN typeof(service_origin) = 'text' AND length(CAST(service_origin AS BLOB)) <= 8192 THEN service_origin ELSE '' END AS service_origin,
  CASE WHEN typeof(service_id) = 'text' AND length(CAST(service_id AS BLOB)) = 36 THEN service_id ELSE '' END AS service_id,
  CASE WHEN typeof(native_origin) = 'text' AND length(CAST(native_origin AS BLOB)) <= 8192 THEN native_origin ELSE '' END AS native_origin,
  CASE WHEN typeof(offer_digest) = 'text' AND length(CAST(offer_digest AS BLOB)) = 64 THEN offer_digest ELSE '' END AS offer_digest,
  CAST(CASE WHEN typeof(identity) = 'blob' THEN length(identity) ELSE -1 END AS INTEGER) AS identity_bytes,
  CAST(CASE WHEN typeof(offer) = 'blob' THEN length(offer) ELSE -1 END AS INTEGER) AS offer_bytes,
  CASE WHEN state IN ('retained', 'cancelled', 'frozen') THEN state ELSE '' END AS state,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes
  FROM owner_custody_command_offers WHERE native_origin = @native_origin LIMIT 2;

-- name: OwnerCommandOfferValue :many
SELECT identity, offer FROM owner_custody_command_offers WHERE address = @address
  AND typeof(identity) = 'blob' AND length(identity) <= 8192
  AND typeof(offer) = 'blob' AND length(offer) <= CAST(@offer_limit AS INTEGER) LIMIT 2;

-- name: OwnerCommandOfferCount :one
SELECT CAST(COUNT(*) AS INTEGER) AS offers FROM owner_custody_command_offers WHERE parent = @parent;

-- name: InsertOwnerCommandOffer :exec
INSERT INTO owner_custody_command_offers(address, parent, service_origin, service_id, identity,
  native_origin, offer_digest, offer, state, reserved_bytes)
VALUES (@address, @parent, @service_origin, @service_id, @identity,
  @native_origin, @offer_digest, @offer, 'retained', @reserved_bytes);

-- name: CancelOwnerCommandOffers :exec
UPDATE owner_custody_command_offers SET state = CASE WHEN state = 'frozen' THEN 'frozen' ELSE 'cancelled' END
WHERE service_origin = @service_origin;

-- name: CancelOwnerAllocatedChild :exec
UPDATE owner_custody_children SET state = CASE WHEN state = 'frozen' THEN 'frozen' ELSE 'cancelled' END
WHERE origin = @origin;

-- name: OwnerUnreleasedRun :one
SELECT CAST(EXISTS(SELECT 1 FROM owner_custody_tools WHERE run_custody != 'released' LIMIT 1) AS INTEGER) AS unreleased;

-- name: DischargeOwnerRun :exec
UPDATE owner_custody_tools SET run_custody = 'released'
WHERE address = @address AND state = 'retained' AND outcome = @outcome AND run_custody = 'unreleased';

-- name: OwnerEnrollmentHeader :many
SELECT CAST(CASE WHEN typeof(schema) = 'integer' THEN schema ELSE -1 END AS INTEGER) AS schema,
  CASE WHEN typeof(session_id) = 'text' AND length(CAST(session_id AS BLOB)) <= 36 THEN session_id ELSE '' END AS session_id,
  CAST(CASE WHEN typeof(binding) = 'blob' THEN length(binding) ELSE -1 END AS INTEGER) AS binding_size,
  CAST(CASE WHEN typeof(descriptor_digest) = 'blob' THEN length(descriptor_digest) ELSE -1 END AS INTEGER) AS descriptor_digest_size,
  CAST(CASE WHEN typeof(enrollment_digest) = 'blob' THEN length(enrollment_digest) ELSE -1 END AS INTEGER) AS enrollment_digest_size,
  CAST(CASE WHEN typeof(enrollment_bytes) = 'blob' THEN length(enrollment_bytes) ELSE -1 END AS INTEGER) AS enrollment_bytes_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_custody_enrollment WHERE singleton = @singleton LIMIT 2;

-- name: OwnerEnrollmentBody :many
SELECT binding, descriptor_digest, enrollment_digest, enrollment_bytes FROM owner_custody_enrollment WHERE singleton = @singleton AND (typeof(binding) = 'blob' AND length(binding) <= 1024) AND (typeof(descriptor_digest) = 'blob' AND length(descriptor_digest) <= 32) AND (typeof(enrollment_digest) = 'blob' AND length(enrollment_digest) <= 32) AND (typeof(enrollment_bytes) = 'blob' AND length(enrollment_bytes) <= 262144) LIMIT 2;

-- name: InsertOwnerEnrollment :exec
INSERT INTO owner_custody_enrollment(singleton, schema, session_id, binding, descriptor_digest, enrollment_digest, enrollment_bytes, reserved_bytes) VALUES (@singleton, @schema, @session_id, @binding, @descriptor_digest, @enrollment_digest, @enrollment_bytes, @reserved_bytes);

-- name: OwnerGenerationHeader :many
SELECT CAST(CASE WHEN typeof(generation_key) = 'blob' THEN length(generation_key) ELSE -1 END AS INTEGER) AS generation_key_size,
  CASE WHEN typeof(owner_use) = 'text' AND length(CAST(owner_use AS BLOB)) = 36 THEN owner_use ELSE '' END AS owner_use,
  CAST(CASE WHEN typeof(association) = 'blob' THEN length(association) ELSE -1 END AS INTEGER) AS association_size,
  CAST(CASE WHEN typeof(digest) = 'blob' THEN length(digest) ELSE -1 END AS INTEGER) AS digest_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_generation_associations WHERE generation_key = @generation_key LIMIT 2;

-- name: OwnerGenerationBody :many
SELECT generation_key, association, digest FROM owner_generation_associations WHERE generation_key = @generation_key AND (typeof(generation_key) = 'blob' AND length(generation_key) <= 1024) AND (typeof(association) = 'blob' AND length(association) <= 1024) AND (typeof(digest) = 'blob' AND length(digest) <= 32) LIMIT 2;

-- name: InsertOwnerGeneration :exec
INSERT INTO owner_generation_associations(generation_key, owner_use, association, digest, reserved_bytes) VALUES (@generation_key, @owner_use, @association, @digest, @reserved_bytes);

-- name: OwnerGenerationCloseHeader :many
SELECT CAST(CASE WHEN typeof(generation_key) = 'blob' THEN length(generation_key) ELSE -1 END AS INTEGER) AS generation_key_size,
  CAST(CASE WHEN typeof(close_record) = 'blob' THEN length(close_record) ELSE -1 END AS INTEGER) AS close_record_size,
  CAST(CASE WHEN typeof(digest) = 'blob' THEN length(digest) ELSE -1 END AS INTEGER) AS digest_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_generation_closes WHERE generation_key = @generation_key LIMIT 2;

-- name: OwnerGenerationCloseBody :many
SELECT generation_key, close_record, digest FROM owner_generation_closes WHERE generation_key = @generation_key AND (typeof(generation_key) = 'blob' AND length(generation_key) <= 1024) AND (typeof(close_record) = 'blob' AND length(close_record) <= 262144) AND (typeof(digest) = 'blob' AND length(digest) <= 32) LIMIT 2;

-- name: InsertOwnerGenerationClose :exec
INSERT INTO owner_generation_closes(generation_key, close_record, digest, reserved_bytes) VALUES (@generation_key, @close_record, @digest, @reserved_bytes);

-- name: OwnerToolGenerationHeader :many
SELECT CAST(CASE WHEN typeof(canonical_tool) = 'blob' THEN length(canonical_tool) ELSE -1 END AS INTEGER) AS canonical_tool_size,
  CAST(CASE WHEN typeof(generation_key) = 'blob' THEN length(generation_key) ELSE -1 END AS INTEGER) AS generation_key_size,
  CAST(CASE WHEN typeof(enrollment_digest) = 'blob' THEN length(enrollment_digest) ELSE -1 END AS INTEGER) AS enrollment_digest_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_tool_generation WHERE address = @address LIMIT 2;

-- name: OwnerToolGenerationBody :many
SELECT canonical_tool, generation_key, enrollment_digest FROM owner_tool_generation WHERE address = @address AND (typeof(canonical_tool) = 'blob' AND length(canonical_tool) <= 8192) AND (typeof(generation_key) = 'blob' AND length(generation_key) <= 1024) AND (typeof(enrollment_digest) = 'blob' AND length(enrollment_digest) <= 32) LIMIT 2;

-- name: InsertOwnerToolGeneration :exec
INSERT INTO owner_tool_generation(address, canonical_tool, generation_key, enrollment_digest, reserved_bytes) VALUES (@address, @canonical_tool, @generation_key, @enrollment_digest, @reserved_bytes);

-- name: OwnerChildGenerationHeader :many
SELECT CAST(CASE WHEN typeof(canonical_origin) = 'blob' THEN length(canonical_origin) ELSE -1 END AS INTEGER) AS canonical_origin_size,
  CAST(CASE WHEN typeof(generation_key) = 'blob' THEN length(generation_key) ELSE -1 END AS INTEGER) AS generation_key_size,
  CAST(CASE WHEN typeof(enrollment_digest) = 'blob' THEN length(enrollment_digest) ELSE -1 END AS INTEGER) AS enrollment_digest_size,
  CASE WHEN typeof(original_request_id) = 'text' AND length(CAST(original_request_id AS BLOB)) <= 36 THEN original_request_id ELSE '' END AS original_request_id,
  CAST(CASE WHEN typeof(input_digest) = 'blob' THEN length(input_digest) ELSE -1 END AS INTEGER) AS input_digest_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_child_generation WHERE address = @address LIMIT 2;

-- name: OwnerChildGenerationBody :many
SELECT canonical_origin, generation_key, enrollment_digest, input_digest FROM owner_child_generation WHERE address = @address AND (typeof(canonical_origin) = 'blob' AND length(canonical_origin) <= 8192) AND (typeof(generation_key) = 'blob' AND length(generation_key) <= 1024) AND (typeof(enrollment_digest) = 'blob' AND length(enrollment_digest) <= 32) AND (typeof(input_digest) = 'blob' AND length(input_digest) <= 32) LIMIT 2;

-- name: InsertOwnerChildGeneration :exec
INSERT INTO owner_child_generation(address, canonical_origin, generation_key, enrollment_digest, original_request_id, input_digest, reserved_bytes) VALUES (@address, @canonical_origin, @generation_key, @enrollment_digest, @original_request_id, @input_digest, @reserved_bytes);

-- name: OwnerSystemIntentHeader :many
SELECT CAST(CASE WHEN typeof(generation_key) = 'blob' THEN length(generation_key) ELSE -1 END AS INTEGER) AS generation_key_size,
  CASE WHEN typeof(service) = 'text' AND length(CAST(service AS BLOB)) <= 128 THEN service ELSE '' END AS service,
  CASE WHEN typeof(operation) = 'text' AND length(CAST(operation AS BLOB)) <= 36 THEN operation ELSE '' END AS operation,
  CASE WHEN typeof(step) = 'text' AND length(CAST(step AS BLOB)) <= 128 THEN step ELSE '' END AS step,
  CASE WHEN typeof(request_id) = 'text' AND length(CAST(request_id AS BLOB)) <= 36 THEN request_id ELSE '' END AS request_id,
  CAST(CASE WHEN typeof(intent_bytes) = 'blob' THEN length(intent_bytes) ELSE -1 END AS INTEGER) AS intent_bytes_size,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes FROM owner_system_intent WHERE intent_address = @intent_address LIMIT 2;

-- name: OwnerSystemIntentBody :many
SELECT generation_key, intent_bytes FROM owner_system_intent WHERE intent_address = @intent_address AND (typeof(generation_key) = 'blob' AND length(generation_key) <= 1024) AND (typeof(intent_bytes) = 'blob' AND length(intent_bytes) <= 8192) LIMIT 2;

-- name: InsertOwnerSystemIntent :exec
INSERT INTO owner_system_intent(intent_address, generation_key, service, operation, step, request_id, intent_bytes, reserved_bytes) VALUES (@intent_address, @generation_key, @service, @operation, @step, @request_id, @intent_bytes, @reserved_bytes);

-- name: OwnerSystemChildHeader :many
SELECT CASE WHEN child_address IS NULL THEN '' WHEN typeof(child_address) = 'text' AND length(CAST(child_address AS BLOB)) <= 8192 THEN child_address ELSE 'invalid' END AS child_address,
  CAST(CASE WHEN canonical_origin IS NULL THEN 0 WHEN typeof(canonical_origin) = 'blob' THEN length(canonical_origin) ELSE -1 END AS INTEGER) AS origin_size,
  CASE WHEN child_profile IS NULL THEN '' WHEN child_profile IN ('native', 'workspace') THEN child_profile ELSE 'invalid' END AS child_profile
FROM owner_system_intent WHERE intent_address = @intent_address LIMIT 2;

-- name: OwnerSystemChildBody :many
SELECT canonical_origin FROM owner_system_intent WHERE intent_address = @intent_address
  AND (typeof(canonical_origin) = 'blob' AND length(canonical_origin) <= 8192) LIMIT 2;

-- name: AttachOwnerSystemChild :exec
UPDATE owner_system_intent SET child_address = @child_address, canonical_origin = @canonical_origin, child_profile = @child_profile, reserved_bytes = reserved_bytes - 2048 + length(CAST(@child_address AS BLOB)) + length(@canonical_origin) + length(CAST(@child_profile AS BLOB))
WHERE intent_address = @intent_address AND child_address IS NULL AND canonical_origin IS NULL;

-- name: OwnerSystemOrdinal :many
SELECT CAST(CASE WHEN typeof(next_ordinal) = 'integer' THEN next_ordinal ELSE -1 END AS INTEGER) AS next_ordinal,
  CAST(CASE WHEN typeof(reserved_bytes) = 'integer' THEN reserved_bytes ELSE -1 END AS INTEGER) AS reserved_bytes
FROM owner_system_ordinal WHERE service = @service LIMIT 2;

-- name: InsertOwnerSystemOrdinal :exec
INSERT INTO owner_system_ordinal(service, next_ordinal, reserved_bytes) VALUES (@service, 0, @reserved_bytes);

-- name: AdvanceOwnerSystemOrdinal :exec
UPDATE owner_system_ordinal SET next_ordinal = @next_ordinal WHERE service = @service AND next_ordinal = @previous_ordinal;

-- name: OwnerPendingSystemCount :one
SELECT CAST(COUNT(*) AS INTEGER) AS pending FROM owner_system_intent WHERE service = @service AND child_address IS NULL;

-- name: OwnerGenerationInventory :many
SELECT CAST((SELECT COUNT(*) FROM owner_generation_associations) AS INTEGER) AS associations,
  CAST((SELECT COUNT(*) FROM owner_generation_closes) AS INTEGER) AS closes,
  CAST((SELECT COUNT(*) FROM owner_tool_generation) AS INTEGER) AS tools,
  CAST((SELECT COUNT(*) FROM owner_child_generation) AS INTEGER) AS children,
  CAST((SELECT COUNT(*) FROM owner_system_intent) AS INTEGER) AS intents;

-- name: OwnerRegisteredInvalidHeaders :one
SELECT CAST(
(SELECT COUNT(*) FROM owner_custody_enrollment WHERE singleton != 1 OR schema != 1 OR typeof(schema) != 'integer' OR typeof(session_id) != 'text' OR length(CAST(session_id AS BLOB)) != 36 OR typeof(binding) != 'blob' OR length(binding) < 1 OR length(binding) > 1024 OR typeof(descriptor_digest) != 'blob' OR length(descriptor_digest) != 32 OR typeof(enrollment_digest) != 'blob' OR length(enrollment_digest) != 32 OR typeof(enrollment_bytes) != 'blob' OR length(enrollment_bytes) < 1 OR length(enrollment_bytes) > 262144 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(binding) + length(enrollment_bytes) + 228)
  + (SELECT COUNT(*) FROM owner_generation_associations WHERE typeof(generation_key) != 'blob' OR length(generation_key) < 1 OR length(generation_key) > 1024 OR typeof(owner_use) != 'text' OR length(CAST(owner_use AS BLOB)) != 36 OR typeof(association) != 'blob' OR length(association) < 1 OR length(association) > 1024 OR typeof(digest) != 'blob' OR length(digest) != 32 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(generation_key) + length(association) + 196)
  + (SELECT COUNT(*) FROM owner_generation_closes WHERE typeof(generation_key) != 'blob' OR length(generation_key) < 1 OR length(generation_key) > 1024 OR typeof(close_record) != 'blob' OR length(close_record) < 1 OR length(close_record) > 262144 OR typeof(digest) != 'blob' OR length(digest) != 32 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(generation_key) + length(close_record) + 160)
  + (SELECT COUNT(*) FROM owner_tool_generation WHERE typeof(address) != 'text' OR length(CAST(address AS BLOB)) < 1 OR length(CAST(address AS BLOB)) > 8192 OR typeof(canonical_tool) != 'blob' OR length(canonical_tool) < 1 OR length(canonical_tool) > 8192 OR typeof(generation_key) != 'blob' OR length(generation_key) < 1 OR length(generation_key) > 1024 OR typeof(enrollment_digest) != 'blob' OR length(enrollment_digest) != 32 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(CAST(address AS BLOB)) + length(canonical_tool) + length(generation_key) + 160)
  + (SELECT COUNT(*) FROM owner_child_generation WHERE typeof(address) != 'text' OR length(CAST(address AS BLOB)) < 1 OR length(CAST(address AS BLOB)) > 8192 OR typeof(canonical_origin) != 'blob' OR length(canonical_origin) < 1 OR length(canonical_origin) > 8192 OR typeof(generation_key) != 'blob' OR length(generation_key) < 1 OR length(generation_key) > 1024 OR typeof(enrollment_digest) != 'blob' OR length(enrollment_digest) != 32 OR typeof(original_request_id) != 'text' OR length(CAST(original_request_id AS BLOB)) != 36 OR typeof(input_digest) != 'blob' OR length(input_digest) != 32 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(CAST(address AS BLOB)) + length(canonical_origin) + length(generation_key) + 228)
  + (SELECT COUNT(*) FROM owner_system_intent WHERE typeof(intent_address) != 'text' OR length(CAST(intent_address AS BLOB)) < 1 OR length(CAST(intent_address AS BLOB)) > 8192 OR typeof(generation_key) != 'blob' OR length(generation_key) < 1 OR length(generation_key) > 1024 OR typeof(service) != 'text' OR service NOT IN ('command-preparation','compiler','satellite-launch','lsp','worktree-observation','workspace-administration') OR typeof(operation) != 'text' OR length(CAST(operation AS BLOB)) != 36 OR typeof(step) != 'text' OR length(CAST(step AS BLOB)) < 1 OR length(CAST(step AS BLOB)) > 128 OR typeof(request_id) != 'text' OR length(CAST(request_id AS BLOB)) != 36 OR typeof(intent_bytes) != 'blob' OR length(intent_bytes) < 1 OR length(intent_bytes) > 8192 OR (child_address IS NULL AND (canonical_origin IS NOT NULL OR child_profile IS NOT NULL)) OR (child_address IS NOT NULL AND (typeof(child_address) != 'text' OR length(CAST(child_address AS BLOB)) < 1 OR length(CAST(child_address AS BLOB)) > 8192 OR typeof(canonical_origin) != 'blob' OR length(canonical_origin) < 1 OR length(canonical_origin) > 8192 OR child_profile IS NULL OR child_profile NOT IN ('native','workspace'))) OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(CAST(intent_address AS BLOB)) + length(generation_key) + length(CAST(service AS BLOB)) + 36 + length(CAST(step AS BLOB)) + 36 + length(intent_bytes) + 128 + CASE WHEN child_address IS NULL THEN 2048 ELSE length(CAST(child_address AS BLOB)) + length(canonical_origin) + length(CAST(child_profile AS BLOB)) END)
  + (SELECT COUNT(*) FROM owner_system_ordinal WHERE typeof(service) != 'text' OR service NOT IN ('command-preparation','compiler','satellite-launch','lsp','worktree-observation','workspace-administration') OR typeof(next_ordinal) != 'integer' OR next_ordinal < 0 OR next_ordinal > 4096 OR typeof(reserved_bytes) != 'integer' OR reserved_bytes < length(CAST(service AS BLOB)) + 144)
  AS INTEGER) AS invalid;

-- name: OwnerNextGeneration :many
SELECT generation_key FROM owner_generation_associations WHERE generation_key > @generation_key ORDER BY generation_key LIMIT 1;

-- name: OwnerNextClose :many
SELECT generation_key FROM owner_generation_closes WHERE generation_key > @generation_key ORDER BY generation_key LIMIT 1;

-- name: OwnerNextToolGeneration :many
SELECT address FROM owner_tool_generation WHERE address > @address ORDER BY address LIMIT 1;

-- name: OwnerNextChildGeneration :many
SELECT address FROM owner_child_generation WHERE address > @address ORDER BY address LIMIT 1;

-- name: OwnerNextSystemIntent :many
SELECT intent_address FROM owner_system_intent WHERE intent_address > @intent_address ORDER BY intent_address LIMIT 1;
