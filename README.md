# Dynamic Records Meritfront

Dyanmic Records Meritfront contains some helpers methods for active record. These methods have the goal of allowing one to
1. communicate with the frontend quicker and more effectively through Global HashIds
2. communicate with the backend more effectively with raw sql queries. This becomes especially relevant when you hit the limits of Active Record Relations and the usual way of querying in rails. For instance, if you have a page-long dynamic sql query.

I dont tend to get much feedback, so any given would be appreciated.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dynamic-records-meritfront'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install dynamic-records-meritfront

## Usage

### Apply to your ApplicationRecord class as such

```ruby
class ApplicationRecord < ActiveRecord::Base
	self.abstract_class = true
	include DynamicRecordsMeritfront
end
```

### SQL methods

These are methods written for easier sql usage.

#### has_run_migration?(nm)

put in a string name of the migration's class and it will say if it has allready run the migration.
good during enum migrations as the code to migrate wont run if enumerate is there 
as it is not yet enumerated (causing an error when it loads the class that will have the
enumeration in it). This can lead it to being impossible to commit clean code.

<details><summary>example usage</summary>
only load relationa if it exists in the database

```ruby
if ApplicationRecord.has_run_migration?('UserImageRelationsTwo')
    class UserImageRelation < ApplicationRecord
        belongs_to :imageable, polymorphic: true
        belongs_to :image
    end
else
    class UserImageRelation; end
end

```
</details>

#### has_association?(*args)

accepts a list, checks if the model contains those associations

<details><summary>example usage</summary>
Check if object is a votable class

```ruby
obj = Comment.first
obj.has_association?(:votes) #true
obj = User.first
obj.has_association?(:votes) #false
```
</details>

#### self.headache_sql(name, sql, opts = { })
A better and safer way to write sql.
with options: 
- instantiate_class: returns User, Post, etc objects instead of straight sql output.
    I prefer doing the alterantive
        ```User.headache_sql(...)```
        which is also supported
- prepare: sets whether the db will preprocess the strategy for lookup (defaults true) (have not verified the prepared-ness)
- name_modifiers: allows one to change the preprocess associated name, useful in cases of dynamic sql.
- multi_query: allows more than one query (you can seperate an insert and an update with ';' I dont know how else to say it.)
    this disables other options including arguments (except name_modifiers). Not sure how it effects prepared statements.
- async: Gets passed to ActiveRecord::Base.connection.exec_query as a parameter. See that methods documentation for more. I was looking through the source code, and I think it only effects how it logs to the logfile?
- other options: considered sql arguments

<details>
<summary>example usage</summary>
Delete Friend Requests between two users after they have become friends.

```ruby
    ApplicationRecord.headache_sql("remove_friend_requests_before_creating_friend", %Q{
        DELETE FROM friend_requests
        WHERE (requestie_id = :uid and requester_id = :other_user_id) OR
            (requester_id = :uid and requestie_id = :other_user_id)
    }, uid: Current.user.id, other_user_id: other_user.id)
```
</details>

<details>
<summary>dynamic sql example usage</summary>
Get all users who have made a friend request to a particular user with an optional limit.
This is an example of why this method is good for dynamic prepared statements.

```ruby
    return User.headache_sql('get_friend_requests', %Q{
        SELECT * FROM (
            SELECT other_user.id, ..., friend_requests.created_at
            FROM users
                INNER JOIN friend_requests ON users.id = friend_requests.requestie_id
                INNER JOIN users other_user ON friend_requests.requester_id = other_user.id
            WHERE users.id = :uid
        ) AS all_friend_requests
        ORDER BY all_friend_requests.created_at DESC
        #{"LIMIT :limit" if limit > 0}
    }, uid: u, limit: limit, name_modifiers: [
        limit > 0 ? 'limited' : nil
    ])
```
</details>
<details>
<summary>example usage with selecting records that match list of ids</summary>
Get users who match a list of ids. Uses a postgresql Array, see the potential issues section

```ruby
	id_list = [1,2,3]
	return User.headache_sql('get_usrs', %Q{
		SELECT * FROM users WHERE id = ANY (:id_list)
	}, id_list: id_list)
```
</details>
	
<details>
<summary>example usage a custom upsert</summary>
Do an upsert

```ruby
	rows = uzrs.map{|u| [
		u.id,		#user_id
		self.id,	#conversation_id
		from,		#invited_by
		t,		#created_at
		t,		#updated_at
	]}
	ApplicationRecord.headache_sql("upsert_conversation_invites_2", %Q{
		INSERT INTO conversation_participants (user_id, conversation_id, invited_by, created_at, updated_at)
		VALUES :rows
		ON CONFLICT (conversation_id,user_id)
		DO UPDATE SET updated_at = :time
	}, rows: rows, time: t)
```
This will output sql similar to below. Note this can be done for multiple conversation_participants. Also note that it only sent one time variable as an argument as headache_sql detected that we were sending duplicate information.
```sql
	INSERT INTO conversation_participants (user_id, conversation_id, invited_by, created_at, updated_at)
	VALUES ($1,$2,$3,$4,$4)
	ON CONFLICT (conversation_id,user_id)
	DO UPDATE SET updated_at = $4
	-- [["rows_1", 15], ["rows_2", 67], ["rows_3", 6], ["rows_4", "2022-10-13 20:49:27.441372"]]
```
</details>
	
	

#### self.headache_preload(records, associations)
Preloads from a list of records, and not from a ActiveRecord_Relation. This will be useful when using the above headache_sql method (as it returns a list of records, and not a record relation).

<details>
<summary>example usage</summary>
Preload :votes on some comments. :votes is an active record has_many relation.

```ruby
    comments = Comment.headache_sql('get_comments', %Q{
        SELECT * FROM comments LIMIT 4
    })
    ApplicationRecord.headache_preload(comments, [:votes])
    puts comments[0].votes #this line should be preloaded and hence not call the database
```
</details>
	
### Hashed Global IDS

hashed global ids look like this: "gid://meritfront/User/K9YI4K". They also have an optional tag so it can also look like "gid://meritfront/User/K9YI4K@user_image". They are based on global ids.

I have been using hgids (Hashed Global IDs) for a while now and they have some unique benefits in front-end back-end communication. This is as they:
1. hash the id which is good practice
2. provide a way to have tags, this is good when updating different UI elements dynamically from the backend. For instance updating the @user_image without affecting the @user_name
3. Carry the class with them, this can allow for more abstract and efficient code, and prevents id collisions between diffrent classes.

#### methods from the hashid-rails gem

See the hashid-rails gem for more (https://github.com/jcypret/hashid-rails). Also note that I aliased .hashid to .hid and .find_by_hashid to .hfind

#### methods from this gem

1. hgid(tag: nil) - get the hgid with optional tag. Aliased to ghid
2. hgid_as_selector(str, attribute: 'id') - get a css selector for the hgid, good for updating the front-end (especially over cable-ready and morphdom operations)
3. self.locate_hgid(hgid_string, with_associations: nil, returns_nil: false) - locates the database record from a hgid. Here are some examples of usage:
    - ApplicationRecord.locate_hgid(hgid) - <b>DANGEROUS</b> will return any object referenced by the hgid.
    - User.locate_hgid(hgid) - locates the User record but only if the hgid references a user class. Fires an error if not.
    - ApplicationRecord.locate_hgid(hgid, with_associations: [:votes]) - locates the record but only if the  record's class has a :votes active record association. So for instance, you can accept only votable objects for upvote functionality. Fires an error if the hgid does not match.
    - User.locate_hgid(hgid, returns_nil: true) - locates the hgid but only if it is the user class. Returns nil if not.
4. get_hgid_tag(hgid) - returns the tag attached to the hgid
5. self.blind_hgid(id, tag: nil, encode: true) - creates a hgid without bringing the object down from the database. Useful with hashid-rails encode_id and decode_id methods.

## Potential Issues

This gem was made with a postgresql database. Although most of the headache_sql code <i>should</i> be usable between databases, there is no abstracted ActiveRecord array type, and no similar classes to ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array for non-postgresql databases (at least, none I could find). I am not 100% sure that it will be an issue, but it might be.

Let me know if this actually becomes an issue for someone and I will throw in a workaround.

## Next Up
- I have the beginnings of something called swiss_instaload in mind, which will load multiple tables at the same time. For instance instead of Doing a ```usrs = User.all``` combined with a ```usrs.preload(:votes)```, which takes two sql requests, it could be done in one. Its kind of a crazy and dubious idea (efficiency wise), but I have a working prototype. It works by casting everything to json before returning it from the database. There might be a better way to do that long term though.
- will be changing names from headache_* which is a bit negative to swiss_* as in swiss_army_knife which is known for its wide versitility. headache names will become aliases.
	
## Changelog
	
1.1.10
- Added functionality in headache_sql where for sql arguments that are equal, we only use one sql argument instead of repeating arguments
- Added functionality in headache_sql for 'multi row expressions' which are inputtable as an Array of Arrays. See the upsert example in the headache_sql documentation above for more.
- Added a warning in the README for non-postgresql databases. Contact me if you hit issues and we can work it out.

1.1.11
- Added encode option for blind_hgid to allow creation of just a general gid
	
## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/LukeClancy/dynamic-records-meritfront. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/LukeClancy/dynamic-records-meritfront/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ActiveRecordMeritfront project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/LukeClancy/dynamic-records-meritfront/blob/master/CODE_OF_CONDUCT.md).
