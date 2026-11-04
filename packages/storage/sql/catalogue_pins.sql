-- Catalogue v21: the role pins a session was created with replace the single
-- model key of v10. `pins` is empty for none, otherwise a JSON object from
-- role name to model key. Each existing model becomes the pin `main`, which is
-- all `model` ever meant (protocol-change/107).
ALTER TABLE catalogue_sessions ADD COLUMN pins TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(pins AS BLOB)) <= 1024);
UPDATE catalogue_sessions SET pins = json_object('main', model) WHERE model != '';
ALTER TABLE catalogue_sessions DROP COLUMN model;
