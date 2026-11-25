-- returns: one
-- unique samples_label_index: Label already taken
insert into samples (
  small, big, object, real_number, double_number, amount, label, code,
  short_name, nickname, document, binary_document, feeling, flag, data,
  identifier, happened_at, happened_at_zone, day, clock, tags, scores, rating
) values (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17,
  $18, $19, $20, $21, $22, $23
)
returning id
