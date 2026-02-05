source "https://rubygems.org"

# Jekyll static site generator
gem "jekyll", "~> 4.2.1"
gem "json"

# Gems that are leaving the Ruby standard library in 3.4+
gem "csv"
gem "base64"
gem "bigdecimal"
gem "logger"

# Jekyll plugins
group :jekyll_plugins do
  gem "jekyll-feed", "~> 0.12"
end

# Windows and JRuby does not include zoneinfo files, so bundle the tzinfo-data gem
# and associated library.
platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", "~> 1.2"
  gem "tzinfo-data"
end

# Performance-booster for watching directories on Windows
gem "wdm", "~> 0.1.1", :platforms => [:mingw, :x64_mingw, :mswin]

# Theme
gem "moonwalk"
