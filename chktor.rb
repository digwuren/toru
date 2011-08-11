#! /usr/bin/ruby

require 'getoptlong'
require 'set'
require 'digest/sha1'

IDENTIFICATION = 'chktor 0.1'
USAGE = <<"EOF"
chktor -- check whether a BitTorrent file matches a file or directory

usage: chktor [-q] [-xDIR] filename.torrent

 -q, --quiet        check quietly
 -x, --extract=DIR  extract valid pieces into the given directory as
                    separate files (named by piece number)

 --help             show this usage
 --version          show version data

EOF

#### Bdecoding

# Parse a bencoded string and return the object represented by it.
def bdecode source
    object, end_offset = bdecode_part source, 0
    raise 'bdecode error' unless end_offset == source.length
    return object
end

# Given a bencoded string and offset in it, parse the object starting at that
# offset.  Return the parsed object and offset in the source string immediately
# past the object's end.
def bdecode_part source, offset
    case source[offset]

    when ?0 .. ?9 then # string
        length = 0
        while (?0 .. ?9).include? source[offset] do
            length = length * 10 + source[offset] - ?0
            offset += 1
        end
        raise 'bdecode error' unless source[offset] == ?:
        offset += 1
        content = source[offset ... offset + length]
        raise 'bdecode error' unless content.length == length
        return content, offset + length

    when ?d then # dictionary
        dictionary = {}
        last_key = nil # we use this to check strictly ascending key order
        offset += 1
        until source[offset] == ?e do
            key, offset = bdecode_part source, offset
            raise 'bdecode error' unless key.is_a? String
            raise 'bdecode error' if last_key and !(key > last_key)
            value, offset = bdecode_part source, offset
            dictionary[key] = value
            last_key = key
        end
        offset += 1
        return dictionary, offset

    when ?l then # list
        list = []
        offset += 1
        until source[offset] == ?e do
            item, offset = bdecode_part source, offset
            list.push item
        end
        offset += 1
        return list, offset

    when ?i then # integer
        offset += 1
        end_offset = source.index(?e, offset)
        raise 'bdecode error' if end_offset.nil?
        integer_face = source[offset ... end_offset]
        # Going by the foundational principle that there's only one way to
        # properly bencode an object, it's obvious that plus signs and extra
        # lead zeroes are verboten in bencoded integers.
        raise 'bdecode error' unless integer_face =~ /\A(0|-?[1-9]\d*)\Z/
        value = integer_face.to_i
        offset = end_offset + 1
        return value, offset

    else
        raise "Unknown bdecode object marker #{source[offset].chr.inspect}"

    end
end

# Cursor for traversing over the file list piecewise
class Multifile_Cursor
    attr_accessor :initial_skip

    # file_entries comes straight from a multifile torrent file
    def initialize file_entries
        super()
        @file_entries = file_entries
        @current_file_index = 0
        @initial_skip = 0
        return
    end

    # Has the cursor reached end of the file list?
    def eof?
        return @current_file_index >= @file_entries.length
    end

    # FIXME: shouldn't this be inlined?
    def current_file_name
        raise 'Assertion failed' if eof?
        return File::join(*@file_entries[@current_file_index]['path'])
    end

    # FIXME: shouldn't this be inlined?
    def current_file_length
        raise 'Assertion failed' if eof?
        return @file_entries[@current_file_index]['length']
    end

    # Advance the cursor by given piece_length.
    # Return [[filename, begin_offset ... end_offset, file_expected_size], ...].
    def step piece_length
        fragments = []
        bytes_left = piece_length
        while bytes_left > 0 and !eof? do
            filename = current_file_name
            start_offset = @initial_skip
            if start_offset + bytes_left > current_file_length then
                end_offset = current_file_length
                bytes_left -= current_file_length - start_offset
                fragments.push [current_file_name, start_offset ... end_offset, current_file_length]
                # advance to next file
                @current_file_index += 1
                @initial_skip = 0
            else
                end_offset = start_offset + bytes_left
                fragments.push [current_file_name, start_offset ... end_offset, current_file_length]
                @initial_skip += bytes_left
                bytes_left = 0
            end
        end
        return fragments
    end
end

#### Parse command line

$quiet = false
$extract_valid_pieces = nil # if true, holds the directory name

$0 = 'chktor' # set our name for GetoptLong's error reporting

begin
    GetoptLong::new(
        ['--quiet', '-q', GetoptLong::NO_ARGUMENT],
        ['--extract-valid-pieces', '-x', GetoptLong::REQUIRED_ARGUMENT],
        ['--help', '-h', GetoptLong::NO_ARGUMENT],
        ['--version', '-V', GetoptLong::NO_ARGUMENT]
    ).each do |opt, arg|
        case opt
        when '--quiet' then
            $quiet = true
        when '--extract' then
            raise "chktor: #{arg}: not a directory" unless File::directory? arg
            $extract_valid_pieces = arg
        when '--help' then
            puts USAGE
            exit 0
        when '--version' then
            puts IDENTIFICATION
            exit 0
        end
    end
rescue GetoptLong::InvalidOption, GetoptLong::MissingArgument
    # the error has already been reported by GetoptLong#each
    exit 1
end

unless ARGV.length == 1 then
    $stderr.puts "chktor: argument count mismatch"
    exit 1
end

$torrent_filename = ARGV[0]

#### The work begins here

torrent_data = bdecode IO::read($torrent_filename)

errors_detected = false

piece_data = torrent_data['info']['pieces']
raise 'Type mismatch' unless piece_data.is_a? String

piece_length = torrent_data['info']['piece length']
raise 'Type mismatch' unless piece_length.is_a? Integer

def each_nondir_descendant dir, base_dir = '.', &thunk
    Dir::entries(File::join(base_dir, dir)).each do |entry|
        next if ['.', '..'].include? entry
        qentry = dir == '.' ? entry : File::join(dir, entry)
        if File::directory? File::join(base_dir, qentry) then
            each_nondir_descendant qentry, base_dir, &thunk
        else
            yield qentry
        end
    end
    return
end

unless torrent_data['info']['files'] then
    # single file
    filename = torrent_data['info']['name']
    raise 'Type mismatch' unless filename.is_a? String
    full_length = torrent_data['info']['length']
    raise 'Type mismatch' unless full_length.is_a? Integer
    expected_piece_count = (full_length + piece_length - 1) / piece_length
    raise 'Piece count mismatch' unless piece_data.length == (expected_piece_count * 20)

    if torrent_data['info']['md5sum'] then
        $stderr.puts "warning: ignoring MD5 checksum"
    end

    # synthesise a file array of the single file
    dirname = '.'
    # note that the filename will be sanity-checked further below
    file_array = [{'path' => [filename], 'length' => full_length}]
else
    # multiple files
    dirname = torrent_data['info']['name']
    raise 'Invalid base directory name' if dirname.include? ?/ or ['.', '..'].include? dirname
    file_array = torrent_data['info']['files']
end

raise 'Type mismatch' unless file_array.is_a? Array
full_length = 0
file_array.each do |file_item|
    raise 'Type mismatch' unless file_item['path'].is_a? Array and file_item['path'].all?{|c| c.is_a? String and not(c.include? ?/) and not ['.', '..'].include? c}
    raise 'Type mismatch' unless file_item['length'].is_a? Integer and file_item['length'] >= 0
    full_length += file_item['length']
end
puts "Full length: #{full_length}"

expected_piece_count = (full_length + piece_length - 1) / piece_length
raise 'Piece count mismatch' unless piece_data.length == (expected_piece_count * 20)

raise "Content directory #{dirname.inspect} missing" unless File::directory? dirname

cursor = Multifile_Cursor::new file_array
cursor.initial_skip = 0
(0 ... expected_piece_count).each do |piece_index|
    expected_piece_hash, = piece_data[piece_index * 20 ... (piece_index + 1) * 20].unpack 'H*'
    piece_content = ''
    acquisition_failed = false
    fragments = cursor.step piece_length
    display_fragments = fragments.map do |filename, range, expected_file_size|
        [range.begin != 0 ? "... " : "", filename, range.end != expected_file_size ? " ..." : ""].join ''
    end
    print "##{piece_index}/#{expected_piece_count} (#{display_fragments.join ', '}) " unless $quiet
    $stdout.flush
    fragments.each do |filename, range, expected_file_size|
        port = nil
        begin
            port = open(File::join(dirname, filename), 'rb')
        rescue Errno::ENOENT
            acquisition_failed = true
            errors_detected = true
            # we'll continue anyway so as to be able to determine the presence of following files in this fragment
            next
        end
        if port.stat.size != expected_file_size then
            puts "File #{filename} size mismatch: expected #{expected_file_size}, actual #{port.stat.size}"
            errors_detected = true
            # but we're not ceasing acquisition of this piece
        end
        port.seek range.begin
        subpiece = port.read(range.end - range.begin)
        unless subpiece.length == range.end - range.begin then
            acquisition_failed = true
            errors_detected = true
        end
        port.close
        piece_content << subpiece
    end
    unless acquisition_failed then
        actual_piece_hash = Digest::SHA1.hexdigest piece_content
        if actual_piece_hash == expected_piece_hash then
            print " ok" unless $quiet
            if $extract_valid_pieces then
                open "#{File::join $extract_valid_pieces, piece_index.to_s}", 'wb' do |port|
                    port.write piece_content
                end
                print " saved" unless $quiet
            end
            puts unless $quiet
        else
            puts " HASH MISMATCH" unless $quiet
            errors_detected = true
        end
    else
        puts " ACQUISITION FAILED" unless $quiet
        errors_detected = true
    end
end

unless dirname == '.' then
    torrent_entry_filename_list = Set::new(file_array.map{|e| File::join(*e['path'])})
    each_nondir_descendant '.', dirname do |filename|
        unless torrent_entry_filename_list.include? filename then
            puts "Extra file: #{filename}"
        end
    end
end

if errors_detected then
    puts "Error(s) detected."
    exit 1
else
    puts "Validation successful."
    exit 0
end
