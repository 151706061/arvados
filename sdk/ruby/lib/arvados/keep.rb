module Keep
  class Locator
    # A Locator is used to parse and manipulate Keep locator strings.
    #
    # Locators obey the following syntax:
    #
    #   locator      ::= address hint*
    #   address      ::= digest size-hint
    #   digest       ::= <32 hexadecimal digits>
    #   size-hint    ::= "+" [0-9]+
    #   hint         ::= "+" hint-type hint-content
    #   hint-type    ::= [A-Z]
    #   hint-content ::= [A-Za-z0-9@_-]+
    #
    # Individual hints may have their own required format:
    #
    #   sign-hint      ::= "+A" <40 lowercase hex digits> "@" sign-timestamp
    #   sign-timestamp ::= <8 lowercase hex digits>
    attr_reader :hash, :hints, :size

    LOCATOR_REGEXP = /^([[:xdigit:]]{32})(\+([[:digit:]]+))?(\+([[:upper:]][[:alnum:]+@_-]*))?$/

    def initialize(hasharg, sizearg, hintarg)
      @hash = hasharg
      @size = sizearg
      @hints = hintarg
    end

    def self.valid? tok
      !!(LOCATOR_REGEXP.match tok)
    end

    # Locator.parse returns a Locator object parsed from the string tok.
    # Returns nil if tok could not be parsed as a valid locator.
    def self.parse(tok)
      begin
        Locator.parse!(tok)
      rescue ArgumentError => e
        nil
      end
    end

    # Locator.parse! returns a Locator object parsed from the string tok,
    # raising an ArgumentError if tok cannot be parsed.
    def self.parse!(tok)
      if tok.nil? or tok.empty?
        raise ArgumentError.new "locator is nil or empty"
      end

      m = LOCATOR_REGEXP.match(tok.strip)
      unless m
        raise ArgumentError.new "not a valid locator #{tok}"
      end

      tokhash, _, toksize, _, trailer = m[1..5]
      tokhints = []
      if trailer
        trailer.split('+').each do |hint|
          if hint =~ /^[[:upper:]][[:alnum:]@_-]+$/
            tokhints.push(hint)
          else
            raise ArgumentError.new "unknown hint #{hint}"
          end
        end
      end

      Locator.new(tokhash, toksize, tokhints)
    end

    # Returns the signature hint supplied with this locator,
    # or nil if the locator was not signed.
    def signature
      @hints.grep(/^A/).first
    end

    # Returns an unsigned Locator.
    def without_signature
      Locator.new(@hash, @size, @hints.reject { |o| o.start_with?("A") })
    end

    def strip_hints
      Locator.new(@hash, @size, [])
    end

    def strip_hints!
      @hints = []
      self
    end

    def to_s
      if @size
        [ @hash, @size, *@hints ].join('+')
      else
        [ @hash, *@hints ].join('+')
      end
    end
  end

  class Manifest
    # Class to parse a manifest text and provide common views of that data.
    def initialize(manifest_text)
      @text = manifest_text
      @files = nil
    end

    def each_line
      return to_enum(__method__) unless block_given?
      @text.each_line do |line|
        stream_name = nil
        block_tokens = []
        file_tokens = []
        line.scan /\S+/ do |token|
          if stream_name.nil?
            stream_name = unescape token
          elsif file_tokens.empty? and Locator.valid? token
            block_tokens << token
          else
            file_tokens << unescape(token)
          end
        end
        # Ignore blank lines
        next if stream_name.nil?
        yield [stream_name, block_tokens, file_tokens]
      end
    end

    def unescape(s)
      # Parse backslash escapes in a Keep manifest stream or file name.
      s.gsub(/\\(\\|[0-7]{3})/) do |_|
        case $1
        when '\\'
          '\\'
        else
          $1.to_i(8).chr
        end
      end
    end

    def split_file_token token
      start_pos, filesize, filename = token.split(':', 3)
      [start_pos.to_i, filesize.to_i, filename]
    end

    def each_file_spec
      return to_enum(__method__, speclist) unless block_given?
      @text.each_line do |line|
        stream_name = nil
        in_file_tokens = false
        line.scan /\S+/ do |token|
          if stream_name.nil?
            stream_name = unescape token
          elsif in_file_tokens or not Locator.valid? token
            in_file_tokens = true
            yield [stream_name] + split_file_token(token)
          end
        end
      end
      true
    end

    def files
      if @files.nil?
        file_sizes = Hash.new(0)
        each_file_spec do |streamname, _, filesize, filename|
          file_sizes[[streamname, filename]] += filesize
        end
        @files = file_sizes.each_pair.map do |(streamname, filename), size|
          [streamname, filename, size]
        end
      end
      @files
    end

    def files_count(stop_after=nil)
      # Return the number of files represented in this manifest.
      # If stop_after is provided, files_count will read the manifest
      # incrementally, and return immediately when it counts that number of
      # files.  This can help you avoid parsing the entire manifest if you
      # just want to check if a small number of files are specified.
      if stop_after.nil? or not @files.nil?
        return files.size
      end
      seen_files = {}
      each_file_spec do |streamname, _, _, filename|
        seen_files[[streamname, filename]] = true
        return stop_after if (seen_files.size >= stop_after)
      end
      seen_files.size
    end

    def exact_file_count?(want_count)
      files_count(want_count + 1) == want_count
    end

    def minimum_file_count?(want_count)
      files_count(want_count) >= want_count
    end

    def has_file?(want_stream, want_file=nil)
      if want_file.nil?
        want_stream, want_file = File.split(want_stream)
      end
      each_file_spec do |streamname, _, _, name|
        if streamname == want_stream and name == want_file
          return true
        end
      end
      false
    end
  end
end
