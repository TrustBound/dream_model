-- returns: one Sample
select
  id, small, big, object, real_number, double_number, amount, label, code,
  short_name, nickname, document, binary_document, feeling, flag, data,
  identifier, happened_at, happened_at_zone, day, clock, tags, scores, rating
from samples where id = $1
