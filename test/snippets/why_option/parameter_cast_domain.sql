insert into notes (id, plain_text) values ($1, $2::strict_text)
returning id
