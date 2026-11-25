merge into users u using posts p on p.user_id = u.id
when not matched by source then delete
when matched then do nothing
returning u.email, p.title
