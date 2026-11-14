-- Catalogue v21: per-session subagent limits configured at creation.
CREATE TABLE catalogue_session_agency(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  fan_out INTEGER CHECK(fan_out IS NULL OR (fan_out >= 1 AND fan_out <= 10000)),
  session_strands INTEGER CHECK(session_strands IS NULL OR (session_strands >= 1 AND session_strands <= 10000)),
  depth_mode TEXT NOT NULL CHECK(depth_mode IN ('inherit', 'bounded', 'unlimited')),
  depth_cap INTEGER CHECK(
    (depth_mode = 'bounded' AND depth_cap >= 1 AND depth_cap <= 256)
    OR (depth_mode != 'bounded' AND depth_cap IS NULL)
  )
);
