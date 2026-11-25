insert into contacts (id, email, note) values ($1, $2, $3)
returning id
