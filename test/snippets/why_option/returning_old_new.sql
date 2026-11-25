insert into users (id, email) values ($1, $2)
returning old.email, new.email
