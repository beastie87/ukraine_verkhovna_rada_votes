require 'scraperwiki'
require 'mechanize'
require 'open-uri'
require 'json'

# Convert Ukrainian vote string to Popolo vote option string
def ukrainian_vote_to_popolo_option(string)
  # This can denote the deputy asked for their vote to be changed
  # TODO: Do we need to do something with this information?
  # e.g. http://w1.c1.rada.gov.ua/pls/radan_gs09/ns_golos?g_id=3107
  string.chomp!("*")

  case string
  when "За"
    "yes"
  when "Проти"
    "no"
  when "Утрималися", "Утримався", "Утрималась"
    "abstain"
  when "Не голосували", "Не голосувала", "Не голосував"
    "not voting"
  when "Відсутні", "Відсутній", "Відсутня"
    "absent"
  else
    raise "Unknown vote option: #{string}"
  end
end

def ukrainian_result_to_popolo(string)
  case string
  when "Рішення прийнято"
    "pass"
  when "Рішення не прийнято"
    "fail"
  else
    raise "Unknown vote_event result: #{string}"
  end
end

def morph_scraper_query(scraper_name, query)
  puts "Querying morph.io scraper, #{scraper_name}, for: #{query}"
  url = "https://api.morph.io/#{scraper_name}/data.json?key=#{ENV['MORPH_API_KEY']}&query=#{CGI.escape(query)}"
  JSON.parse(open(url).read)
end

def full_name_to_abbreviated(full_name)
  parts = full_name.split
  # On the site the last initial becomes a blank space if they don't have a middle name
  last_initial = parts[2] ? parts[2][0] : " "
  "#{parts[0]} #{parts[1][0]}.#{last_initial}."
end

def person_name_to_id(abbreviated_name, faction_name)
  # Special case for 2 people with the same abbreviated name
  # TODO: Remove this hardcoded exception
  # case abbreviated_name
  # when "Тимошенко Ю.В."
  #   case faction_name
  #   when 'Фракція політичної партії "Всеукраїнське об\'єднання "Батьківщина"'
  #     "1792"
  #   when 'Фракція Політичної партії "НАРОДНИЙ ФРОНТ"'
  #     "18141"
  #   when "Позафракційні"
  #     nil # When there's 2 people with the same name in the same faction, we just don't know
  #   else
  #     raise "Unknown faction for special case person #{abbreviated_name}: #{faction_name}"
  #   end
  # when "Бордюг І.Л."
  #   "18040"
  # else
    @name_ids ||= morph_scraper_query("beastie87/ukraine_verkhovna_rada_deputies", "select name, id from 'data'")
    if deputy = @name_ids.find { |r| full_name_to_abbreviated(r["name"]) == abbreviated_name }
      deputy["id"]
    else
      raise "Person ID not found for: #{abbreviated_name}"
    end
  #end
end

def faction_name_to_id(name)
  @factions ||= morph_scraper_query("beastie87/ukraine_verkhovna_rada_deputies",
                                    "SELECT DISTINCT COALESCE(faction_id, 'party/Позафракційні') AS faction_id, COALESCE(faction, 'Позафракційні') AS faction FROM 'data'")
  if faction = @factions.find { |f| f["faction"].gsub(/\s-\s/,'-').sub(/ у Верховній Раді України|  у Верховній Раді України дев'ятого скликання/, '').capitalize.include? name.capitalize }
    faction["faction_id"]
  else
    raise "Faction ID not found for: #{name.capitalize}"
  end
end

# This handles the situation where there are 2 people with
# the same name in the same "faction" (actually it's when
# they don't yet have a faction)
def check_votes_for_exceptions(votes)
  if votes.select { |v| v[:voter_id].nil? }
    exception_ids = ["1792", "18141"]
    votes.map! do |v|
      v[:voter_id] = exception_ids.pop if v[:voter_id].nil?
      v
    end
  else
    votes
  end
end

def scrape_vote_event(vote_event_id, bill, debate_url)
  ScraperWiki::sqliteexecute("BEGIN TRANSACTION")

  base_url = "http://w1.c1.rada.gov.ua/pls/radan_gs09/ns_golos?g_id="
  vote_event_url = base_url + vote_event_id
  puts "Fetching vote event page: #{vote_event_url}"
  vote_event_page = @agent.get(vote_event_url)

  vote_event = {
    organization_id: "rada",
    identifier: vote_event_id,
    title: vote_event_page.at(".head_gol font").text.strip,
    start_date: DateTime.parse(vote_event_page.at(".head_gol").search(:br).first.next.text),
    result: ukrainian_result_to_popolo(vote_event_page.search(".head_gol font").last.text),
    source_url: vote_event_url,
    debate_url: debate_url
  }
  ScraperWiki::save_sqlite([:identifier], vote_event, :vote_events)
  if bill.any?
    ScraperWiki::save_sqlite([:official_id, :vote_event_id], bill.merge(vote_event_id: vote_event[:identifier]), :bills)
  end

  # Vote results by faction
  vote_event_page.search("#01 ul.fr > li").each do |faction|
    faction_name = faction.at(:b).inner_text.gsub("’", "'").squeeze(" ")
    faction_id = faction_name_to_id(faction_name)

    puts "Saving votes for faction: #{faction_name}"
    votes = faction.search(:li).map do |li|
      voter_name = li.at(".dep").text.gsub("’", "'")
      voter_id = person_name_to_id(voter_name, faction_name)

      {
        vote_event_id: vote_event_id,
        voter_id: voter_id,
        group_id: faction_id,
        option: ukrainian_vote_to_popolo_option(li.at(".golos").text)
      }
    end

    # Check for exceptions if this is the "independent" faction
    votes = check_votes_for_exceptions(votes) if faction_name == "Позафракційні"

    ScraperWiki::save_sqlite([:vote_event_id, :voter_id], votes, :votes)
  end

  ScraperWiki::sqliteexecute("COMMIT")
end

def scrape_sitting_date(date)
  plenary_session_url = "http://w1.c1.rada.gov.ua/pls/radan_gs09/ns_el_h2?data=#{date.strftime('%d%m%Y')}&nom_s=3"
  puts "Fetching plenary day: #{plenary_session_url}"
  plenary_session_page = @agent.get(plenary_session_url)
  plenary_session_page.encoding = 'windows-1251'
  vote_events = []
  bill = {}

  plenary_session_page.search("table.tab_1 tr").each do |tr|
    if tr.at("[title='Порівняти']")
      # A vote
      vote_events << {id: tr.at("[title='Порівняти']").attr(:value), bill: bill}
    elsif tr.search(:td).count == 1
      # A normal speech heading
      bill = {}
    elsif tr.search(:td).count == 3 && tr.at("td center b")
      # A bill heading
      bill = {
        official_id: tr.at("td center b").text,
        title: tr.search("td")[1].text,
        url: "http://w1.c1.rada.gov.ua" + tr.at(:a).attr(:href)
      }
    end
  end

  puts "Found #{vote_events.count} vote events to scrape..."
  vote_events.each do |vote_event|
    scrape_vote_event(vote_event[:id], vote_event[:bill], plenary_session_url)
  end
end

def dates_to_parse
  # Only parse a single date - useful for debugging
  return [Date.parse(ENV["MORPH_ONLY_PARSE_DATE"])] if ENV["MORPH_ONLY_PARSE_DATE"]

  start_date = if ENV["MORPH_START_DATE"]
    # Start parsing from a specific date
    Date.parse(ENV["MORPH_START_DATE"])
  else
    # Normal operation - start parsing from the day after the most recent date in the database
    begin
      Date.parse(ScraperWiki.select("start_date FROM vote_events ORDER BY start_date DESC LIMIT 1").first["start_date"]) + 1
    rescue SqliteMagic::NoSuchTable
      raise "No scraped votes found. Set MORPH_START_DATE to tell me what date to start scraping from."
    end
  end
  end_date = Date.today-1
  (start_date..end_date)
end

@agent = Mechanize.new

dates_to_parse.each do |date|
  puts "Checking for votes on: #{date}"
  scrape_sitting_date(date)
end

puts "All done."
