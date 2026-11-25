select u.email, p.title
from users u left join posts p on p.user_id = u.id
