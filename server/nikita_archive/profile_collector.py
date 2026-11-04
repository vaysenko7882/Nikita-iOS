"""One paced observer on the existing Telegram session; no extra logins."""
import asyncio
import hashlib
import json
import time
from telethon import errors, functions, types
from .media_capture import MediaCapture
from .profiles import public_value


class ProfileCollector:
    def __init__(self, client, store):
        self.client, self.store = client, store
        self.capture = MediaCapture(store.archive.media)
        self.gift_checks = {}
        self.avatar_ids = {}
        self.pause_until = 0
        self.request_lock = asyncio.Lock()
        self.rpc_slots = asyncio.Semaphore(3)
        self.hydration_lock = asyncio.Lock()
        self.last_request = 0
        self.pending_stories = set()
        self.story_tasks = set()
        self.dirty_profiles = set()
        self.story_poll_interval = store.STORY_INTERVAL
        self.story_poll_task = None
        self.story_deadlines = {}
        self.availability_versions = {}

    @staticmethod
    def presence_fields(status):
        name = type(status).__name__
        return dict(last_seen_visibility="visible" if name in ("UserStatusOnline","UserStatusOffline") else name,
                    status_hidden_by_me=bool(getattr(status,"by_me",False)))

    async def request(self, value):
        async with self.rpc_slots:
            async with self.request_lock:
                while True:
                    now = time.monotonic()
                    delay = max(0,self.pause_until-now,1-(now-self.last_request))
                    if delay <= 0:
                        break
                    await asyncio.sleep(delay)
                    # Recheck a FLOOD_WAIT extended by another in-flight RPC.
                self.last_request = time.monotonic()
            try:
                # The pacing lock protects start times, not a slow network
                # response. One gift request must not hold up story delivery.
                return await asyncio.wait_for(self.client(value,flood_sleep_threshold=0),30)
            except errors.FloodWaitError as error:
                # Every caller, including background skipped-story hydration,
                # obeys this same deadline before making its next RPC.
                self.pause_until = max(self.pause_until,time.monotonic()+int(error.seconds)+2)
                raise

    def user_update(self, update):
        peer_id = getattr(update,"user_id",None) or getattr(getattr(update,"peer_id",None),"user_id",None)
        if peer_id and self.store.enabled(peer_id):
            is_presence = isinstance(update,getattr(types,"UpdateUserStatus",type(None)))
            is_blocklist = isinstance(update,getattr(types,"UpdatePeerBlocked",type(None)))
            if not is_presence and not is_blocklist:
                self.store.collection(peer_id,"notifications",{"_"+type(update).__name__:public_value(update)},complete=False)
            # These values are the event itself: do not wait for another full
            # scan, which could already contain a later name/photo again.
            fields = {}
            availability = {}
            entity = getattr(update,"_entities",{}).get(peer_id)
            if isinstance(update,types.UpdateUser) and isinstance(entity,types.User) and not entity.min:
                fields = {name:public_value(getattr(entity,name,None)) for name in
                          ("first_name","last_name","username","usernames","premium","verified","scam","fake","emoji_status","color","profile_color")}
                photo_id = getattr(getattr(entity,"photo",None),"photo_id",None)
                fields["current_photo_id"] = str(photo_id) if photo_id else None
                availability.update(self.presence_fields(getattr(entity,"status",None)))
                availability["account_deleted"] = bool(getattr(entity,"deleted",False))
                if photo_id:
                    availability["photo_visible"] = True
            elif isinstance(update,types.UpdateUserName):
                fields = dict(first_name=update.first_name,last_name=update.last_name,
                              username=next((name.username for name in update.usernames if name.active),None),
                              usernames=public_value(update.usernames))
            elif isinstance(update,getattr(types,"UpdateUserPhoto",type(None))):
                photo_id = getattr(getattr(update,"photo",None),"photo_id",None)
                fields = dict(current_photo_id=str(photo_id) if photo_id else None)
                # An absent raw photo does not include fallback-photo privacy.
                # Confirm disappearance in the next paced full-user response.
                if photo_id:
                    availability["photo_visible"] = True
            elif isinstance(update,getattr(types,"UpdateUserEmojiStatus",type(None))):
                fields = dict(emoji_status=public_value(update.emoji_status))
            elif is_presence:
                availability.update(self.presence_fields(update.status))
            if fields:
                self.store.fields(peer_id,fields,partial=True)
            # updatePeerBlocked describes OUR blocklist, never the target's.
            if is_blocklist:
                availability.update(dict(
                    blocked_by_me=bool(update.blocked),
                    blocked_my_stories_from=bool(getattr(update,"blocked_my_stories_from",False))))
            if availability or "current_photo_id" in fields:
                # Even an absent raw photo invalidates a response that started
                # before the update; disappearance itself needs fallback-aware
                # confirmation from the next full-user request.
                self.availability_versions[peer_id] = self.availability_versions.get(peer_id,0)+1
            if availability:
                self.store.observe_availability(peer_id,availability,source="telegram_update",record_general=False)
            self.dirty_profiles.add(peer_id)
            self.store.nudge(peer_id)

    def source(self, peer_id, section, item_id):
        self.capture.source = dict(type="CodeGramProfile",peer_id=peer_id,section=section,item_id=str(item_id))

    def photo(self, peer_id, section, photo):
        self.source(peer_id,section,photo.id)
        descriptor = self.capture.photo(photo,500)
        self.store.associate(peer_id,descriptor)
        return descriptor

    async def stories(self, peer_id, input_peer, selected=None):
        if selected is None:
            response = await self.request(functions.stories.GetPeerStoriesRequest(input_peer))
            stories = response.stories.stories
        else:
            stories = selected
        values, missing = {}, []
        for story in stories:
            if isinstance(story,types.StoryItemSkipped):
                self.store.skipped_story(peer_id,public_value(story))
                missing.append(story.id)
            elif isinstance(story,types.StoryItemDeleted):
                self.store.deleted_story(peer_id,story.id)
        if missing:
            response = await self.request(functions.stories.GetStoriesByIDRequest(input_peer,missing))
            stories = [s for s in stories if not isinstance(s,types.StoryItemSkipped)] + list(response.stories)
        for story in stories:
            if isinstance(story,types.StoryItemDeleted):
                self.store.deleted_story(peer_id,story.id)
            if not isinstance(story,types.StoryItem):
                continue
            self.source(peer_id,"stories",story.id)
            media = story.media
            descriptor, capture_error = None, None
            try:
                if getattr(media,"photo",None):
                    descriptor = self.capture.photo(media.photo,1000)
                elif getattr(media,"document",None):
                    descriptor = self.capture.document(media.document,1000)
                self.store.associate(peer_id,descriptor)
            except Exception as error:
                # A media-reference problem must not discard the received story.
                capture_error = type(error).__name__

            # Views/reactions are volatile counters; retain stable story metadata.
            item = public_value(story)
            for name in ("views","sent_reaction","media"):
                item.pop(name,None)
            item["media"] = descriptor
            if capture_error:
                item["media_capture_error"] = capture_error
            values[str(story.id)] = item
        # A skipped/private item is not evidence that a saved story was deleted.
        self.store.collection(peer_id,"stories",values,complete=selected is None and not missing)

    async def gifts(self, peer_id, input_peer):
        offset, visited, gifts, positions = "", set(), {}, []
        count = 0
        while True:
            page = await self.request(functions.payments.GetSavedStarGiftsRequest(input_peer,offset,100))
            users = {user.id:user for user in page.users}
            chats = {chat.id:chat for chat in getattr(page,"chats",[]) if getattr(chat,"id",None) is not None}
            count = page.count
            for gift in page.gifts:
                value = public_value(gift)
                sender = getattr(gift,"from_id",None)
                sender_id = None if getattr(gift,"name_hidden",False) else getattr(sender,"user_id",None)
                if getattr(gift,"name_hidden",False):
                    value["from_id"] = None
                sender_user = users.get(sender_id)
                if sender_user:
                    value["sender"] = dict(id=str(sender_user.id),first_name=sender_user.first_name,last_name=sender_user.last_name,username=sender_user.username)
                else:
                    chat_id = getattr(sender,"channel_id",None) or getattr(sender,"chat_id",None)
                    chat = None if getattr(gift,"name_hidden",False) else chats.get(chat_id)
                    value["sender"] = dict(id=str(chat.id),title=getattr(chat,"title",""),username=getattr(chat,"username",None)) if chat else None
                # Mutable display/pin flags must not turn an existing gift into a new one.
                source_gift = getattr(gift,"gift",None)
                stable = dict(gift_id=getattr(source_gift,"id",None),date=value.get("date"))
                base = str(getattr(gift,"saved_id",None) or getattr(gift,"msg_id",None) or
                           ("unique:"+str(source_gift.id) if getattr(source_gift,"slug",None) else
                            hashlib.sha256(json.dumps(stable,sort_keys=True).encode()).hexdigest()))
                key, duplicate = base, 0
                while key in gifts:
                    duplicate += 1; key = base+":"+str(duplicate)
                self.source(peer_id,"gifts",key)
                sticker = getattr(getattr(gift,"gift",None),"sticker",None)
                if sticker:
                    value["artwork"] = self.capture.document(sticker,10)
                    self.store.associate(peer_id,value["artwork"])
                gifts[key] = value
                positions.append(key)
            next_offset = getattr(page,"next_offset",None)
            if not next_offset:
                break
            if next_offset in visited:
                raise ValueError("Repeated gift page")
            visited.add(next_offset)
            offset = next_offset
            await asyncio.sleep(0.5)
            if not self.store.enabled(peer_id):
                return
        self.store.collection(peer_id,"gifts",gifts)
        self.store.collection(peer_id,"gifts",{"_visible_order":dict(count=count,order=positions)},complete=False)
        self.gift_checks[peer_id] = time.monotonic()

    async def avatars(self, peer_id, input_peer, signature, extra):
        photos, order = {}, []
        for role,photo in extra:
            if isinstance(photo,types.Photo):
                photos[str(photo.id)] = dict(id=str(photo.id),date=public_value(photo.date),media=self.photo(peer_id,"avatars",photo))
        offset, pages = 0, set()
        while True:
            # Telethon's generic iterator issues its own RPCs; use the same
            # request gate as stories/gifts so pagination cannot bypass backoff.
            page = await self.request(functions.photos.GetUserPhotosRequest(
                types.InputUser(input_peer.user_id,input_peer.access_hash),offset,0,100))
            current = list(page.photos)
            signature_ids = tuple(photo.id for photo in current)
            if current and signature_ids in pages:
                raise ValueError("Repeated avatar page")
            pages.add(signature_ids)
            for photo in current:
                order.append(str(photo.id))
                photos[str(photo.id)] = dict(id=str(photo.id),date=public_value(photo.date),media=self.photo(peer_id,"avatars",photo))
                if not self.store.enabled(peer_id):
                    return
            offset += len(current)
            if len(current)<100 or not hasattr(page,"count") or offset>=page.count:
                break
        self.store.collection(peer_id,"avatars",photos)
        self.avatar_ids[peer_id] = signature

    async def scan(self, peer_id, access_hash, *, include_stories=True):
        input_peer = types.InputPeerUser(peer_id,int(access_hash))
        availability_version = self.availability_versions.get(peer_id,0)
        full = await self.request(functions.users.GetFullUserRequest(types.InputUser(peer_id,int(access_hash))))
        user = next(user for user in full.users if user.id==peer_id)
        info = full.full_user
        photo_id = getattr(getattr(user,"photo",None),"photo_id",None)
        fields = {name:public_value(getattr(user,name,None)) for name in
                  ("first_name","last_name","username","usernames","premium","verified","scam","fake","emoji_status","color","profile_color")}
        fields.update({name:public_value(getattr(info,name,None)) for name in
                       ("about","birthday","personal_channel_id","personal_channel_message","business_work_hours","business_location","business_intro","stargifts_count","saved_music","main_tab","stars_rating","disallowed_gifts","phone_calls_available","phone_calls_private","video_calls_available","voice_messages_forbidden","contact_require_premium","send_paid_messages_stars")})
        fields["current_photo_id"] = str(photo_id) if photo_id else None
        extra_photos = [(role,getattr(info,role,None)) for role in ("profile_photo","fallback_photo","personal_photo")]
        signature = (photo_id,)+tuple(getattr(photo,"id",None) for _,photo in extra_photos)
        fields["fallback_photo_id"] = str(signature[2]) if signature[2] else None
        fields["personal_photo_id"] = str(signature[3]) if signature[3] else None
        old_gift_count = self.store.field_value(peer_id,"stargifts_count")
        self.store.fields(peer_id,fields)
        if availability_version == self.availability_versions.get(peer_id,0):
            self.store.observe_availability(peer_id,dict(
                profile_request="ok",photo_visible=bool(photo_id or signature[2]),about_visible=bool(getattr(info,"about",None)),
                account_deleted=bool(getattr(user,"deleted",False)),blocked_by_me=bool(getattr(info,"blocked",False)),
                blocked_my_stories_from=bool(getattr(info,"blocked_my_stories_from",False)),
                **self.presence_fields(getattr(user,"status",None))))
        # Active stories first: fetch only what this session can actually see.
        warnings = []
        operations = [("Сторис",lambda: self.stories(peer_id,input_peer))] if include_stories else []
        if peer_id not in self.avatar_ids or self.avatar_ids[peer_id] != signature:
            operations.append(("Аватарки",lambda: self.avatars(peer_id,input_peer,signature,extra_photos)))
        if (old_gift_count != fields.get("stargifts_count") or
                time.monotonic()-self.gift_checks.get(peer_id,-100000)>=self.store.GIFT_INTERVAL):
            operations.append(("Подарки",lambda: self.gifts(peer_id,input_peer)))
        for name,operation in operations:
            if not self.store.enabled(peer_id):
                return ""
            try:
                await operation()
            except errors.FloodWaitError:
                raise
            except Exception as error:
                # A restricted collection never blocks unrelated profile changes.
                warnings.append(name+": "+type(error).__name__)
        return "; ".join(warnings)

    async def pushed_story(self, update):
        peer = getattr(update,"peer",None)
        peer_id = getattr(peer,"user_id",None)
        if not peer_id or not self.store.enabled(peer_id):
            return
        story = getattr(update,"story",None)
        if isinstance(story,types.StoryItemDeleted):
            self.store.deleted_story(peer_id,story.id)
        elif isinstance(story,types.StoryItem):
            # No network wait: persist and queue media before processing the
            # next raw update, even when deletion follows seconds later.
            await self.stories(peer_id,None,[story])
        elif isinstance(story,types.StoryItemSkipped):
            self.store.skipped_story(peer_id,public_value(story))
            key = (peer_id,story.id)
            if key not in self.pending_stories and len(self.pending_stories)<128:
                self.pending_stories.add(key)
                task = asyncio.create_task(self.resolve_story(peer_id,story.id))
                self.story_tasks.add(task)
                task.add_done_callback(self.story_tasks.discard)

    async def resolve_story(self, peer_id, story_id):
        try:
            # Only one hydration is in flight; a burst of skipped updates must
            # leave an RPC slot for the dedicated active-story poller.
            async with self.hydration_lock:
                access_hash = self.store.access_hash(peer_id)
                if access_hash is None or time.monotonic()<self.pause_until:
                    return
                peer = types.InputPeerUser(peer_id,int(access_hash))
                response = await self.request(functions.stories.GetStoriesByIDRequest(peer,[story_id]))
                await self.stories(peer_id,peer,list(response.stories))
        except errors.FloodWaitError as error:
            self.pause_until = max(self.pause_until,time.monotonic()+int(error.seconds)+2)
        except Exception:
            # The durable stub remains when content disappeared or was private.
            pass
        finally:
            self.pending_stories.discard((peer_id,story_id))

    async def close(self):
        tasks = list(self.story_tasks)
        if self.story_poll_task is not None:
            tasks.append(self.story_poll_task)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)

    async def poll_stories(self):
        """Poll active stories independently of full profile/gift pagination."""
        while True:
            now = time.monotonic()
            if now < self.pause_until:
                await asyncio.sleep(min(1,self.pause_until-now))
                continue
            enabled = dict(self.store.watching())
            self.story_deadlines = {peer:deadline for peer,deadline in self.story_deadlines.items() if peer in enabled}
            due = sorted(((self.story_deadlines.get(peer,0),peer,access_hash)
                          for peer,access_hash in enabled.items()),key=lambda item:(item[0],item[1]))
            for deadline,peer_id,access_hash in due:
                if deadline > time.monotonic():
                    break
                if not self.store.enabled(peer_id):
                    continue
                delay = self.story_poll_interval
                try:
                    await self.stories(peer_id,types.InputPeerUser(peer_id,int(access_hash)))
                    self.store.story_checked(peer_id)
                except errors.FloodWaitError as error:
                    delay = max(self.story_poll_interval,int(error.seconds)+2)
                    self.pause_until = max(self.pause_until,time.monotonic()+delay)
                    self.store.story_checked(peer_id,"Telegram временно ограничил запросы")
                except Exception as error:
                    # A missing/private story collection never erases history
                    # or changes the separate full-profile check status.
                    self.store.story_checked(peer_id,type(error).__name__)
                    delay = max(self.story_poll_interval,self.store.POLL_INTERVAL)
                self.story_deadlines[peer_id] = time.monotonic()+delay
                if time.monotonic() < self.pause_until:
                    break
                await asyncio.sleep(0)
            next_due = min(self.story_deadlines.values(),default=time.monotonic()+1)
            await asyncio.sleep(max(0.05,min(1,next_due-time.monotonic())))

    async def run(self):
        self.story_poll_task = asyncio.create_task(self.poll_stories())
        try:
            await self.run_profiles()
        finally:
            self.story_poll_task.cancel()
            await asyncio.gather(self.story_poll_task,return_exceptions=True)
            self.story_poll_task = None

    async def run_profiles(self):
        while True:
            if time.monotonic() < self.pause_until:
                await asyncio.sleep(min(30,self.pause_until-time.monotonic()))
                continue
            for peer_id,access_hash in self.store.due():
                self.dirty_profiles.discard(peer_id)
                try:
                    warning = await self.scan(peer_id,access_hash,include_stories=False)
                    self.store.checked(peer_id,warning or "")
                except errors.FloodWaitError as error:
                    delay = max(30,int(error.seconds)+2)
                    self.pause_until = max(self.pause_until,time.monotonic()+delay)
                    self.store.checked(peer_id,"Telegram временно ограничил запросы",delay=delay)
                    break
                except Exception as error:
                    # No usernames, bio, credentials or attachment references in logs.
                    if type(error).__name__ in ("UserPrivacyRestrictedError","UserIdInvalidError","InputUserDeactivatedError"):
                        self.store.observe_availability(peer_id,dict(profile_request="unavailable",reason=type(error).__name__))
                    self.store.checked(peer_id,type(error).__name__,delay=300)
                if peer_id in self.dirty_profiles:
                    self.store.nudge(peer_id)
                await asyncio.sleep(1)
            await asyncio.sleep(1)

