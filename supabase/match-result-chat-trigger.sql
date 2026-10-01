-- Dormie Cup: automatically announce each completed 6-hole match in chat exactly once.
-- Run this in the Supabase SQL Editor.

create table if not exists public.match_result_announcements (
  match_id integer not null,
  segment_end integer not null check (segment_end in (6,12,18)),
  created_at timestamptz not null default now(),
  primary key (match_id, segment_end)
);

create or replace function public.announce_dormie_match_result()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  seg_start integer;
  seg_end integer;
  h integer;
  red_wins integer := 0;
  black_wins integer := 0;
  played integer := 0;
  remaining integer;
  decided boolean := false;
  result_code text;
  red_names text;
  black_names text;
  announcement text;
  claimed integer;
begin
  -- Determine which six-hole match this score belongs to.
  if new.hole_number between 1 and 6 then
    seg_start := 1; seg_end := 6;
  elsif new.hole_number between 7 and 12 then
    seg_start := 7; seg_end := 12;
  elsif new.hole_number between 13 and 18 then
    seg_start := 13; seg_end := 18;
  else
    return new;
  end if;

  -- Recalculate the six-hole match in hole order. A row counts as played when
  -- Red, Black, or Tie has been recorded (ties are stored as 1/1 by the site).
  for h in seg_start..seg_end loop
    declare
      rs numeric := 0;
      bs numeric := 0;
    begin
      select coalesce(red_score,0), coalesce(black_score,0)
        into rs, bs
      from public.hole_scores
      where match_id = new.match_id and hole_number = h;

      if rs > 0 or bs > 0 then
        played := played + 1;
        if rs > 0 and bs = 0 then red_wins := red_wins + 1; end if;
        if bs > 0 and rs = 0 then black_wins := black_wins + 1; end if;

        remaining := 6 - played;
        if abs(red_wins - black_wins) > remaining then
          decided := true;
          exit;
        elsif remaining = 0 then
          decided := true;
          exit;
        end if;
      else
        -- Scoring is sequential in the app; an unplayed hole means this segment
        -- has not yet reached a final result.
        exit;
      end if;
    end;
  end loop;

  if not decided then return new; end if;

  if red_wins > black_wins then result_code := 'R';
  elsif black_wins > red_wins then result_code := 'B';
  else result_code := 'H';
  end if;

  -- Claim this result before posting so multiple connected phones cannot duplicate it.
  insert into public.match_result_announcements(match_id, segment_end)
  values (new.match_id, seg_end)
  on conflict do nothing;
  get diagnostics claimed = row_count;
  if claimed = 0 then return new; end if;

  case new.match_id
    when 1 then red_names := 'Brian Bondurant & Shane Nemechek'; black_names := 'Tyler Metzger & Josh Masrud';
    when 2 then red_names := 'Ryan Sloop & Jason Hoffman'; black_names := 'Jim Hammen & Mark Hernandez';
    when 3 then red_names := 'Ryley Haas & Brent Fry'; black_names := 'Brian Dick & Colin Davis';
    when 4 then red_names := 'Jeremy Zimney & Will Allen'; black_names := 'Jason McCandless & Van Ryan Belanger';
    when 5 then red_names := 'Andrew Madl & Alex Ward'; black_names := 'David Dunn & Chris Brown';
    when 6 then red_names := 'Austin Osborn & Matt Klinger'; black_names := 'Ryan Pidhaichuk & JW Roeder';
    when 7 then red_names := 'Tommy Slaughter & Andrew Firkins'; black_names := 'Jared Dunn & Zach Renn';
    else return new;
  end case;

  if result_code = 'R' then
    announcement := '🏆 MATCH RESULT — ' || red_names || ' win 1 point for Team Red on Hole ' || seg_end || '!';
  elsif result_code = 'B' then
    announcement := '🏆 MATCH RESULT — ' || black_names || ' win 1 point for Team Black on Hole ' || seg_end || '!';
  else
    announcement := '🤝 MATCH HALVED — ' || red_names || ' and ' || black_names || ' each earn ½ point on Hole ' || seg_end || '.';
  end if;

  insert into public.chat_messages(name, message)
  values ('Dormie Cup Live', announcement);

  return new;
exception
  when others then
    -- Never block score entry if the announcement fails.
    return new;
end;
$$;

drop trigger if exists dormie_match_result_chat on public.hole_scores;
create trigger dormie_match_result_chat
after update of red_score, black_score on public.hole_scores
for each row execute function public.announce_dormie_match_result();
