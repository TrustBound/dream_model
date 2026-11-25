insert into notes (id, plain_text) values ($1, $2::text::checked_text)
returning id
