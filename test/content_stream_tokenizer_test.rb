#!/usr/bin/env ruby
# test/content_stream_tokenizer_test.rb
# Proves the plain-character tokenizer emits the same token stream as the
# prior regex hot-path for representative content-stream fixtures.

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/logger'

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_equal(expected, actual, msg)
  assert_true(expected == actual, "#{msg} (expected=#{expected.inspect}, actual=#{actual.inspect})")
end

Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser

# Reference tokenizer: exact pre-optimization regex hot-path behavior.
def regex_tokenize(stream)
  tokens = []
  i = 0
  len = stream.length
  max_tokens = Parser::MAX_TOKENS_PER_STREAM

  while i < len
    break if tokens.length > max_tokens
    c = stream[i]

    if c =~ /[\s\x00]/
      i += 1
      next
    end

    if c == '%'
      eol = stream.index(/[\r\n]/, i) || len
      i = eol + 1
      next
    end

    if c == '('
      depth = 1
      j = i + 1
      while j < len && depth > 0
        if stream[j] == '\\'
          j += 2
          next
        end
        depth += 1 if stream[j] == '('
        depth -= 1 if stream[j] == ')'
        j += 1
      end
      tokens << { type: :string, value: stream[i...j] }
      i = j
      next
    end

    if c == '<' && (i + 1 >= len || stream[i + 1] != '<')
      j = stream.index('>', i) || len
      tokens << { type: :hex_string, value: stream[i..j] }
      i = j + 1
      next
    end

    if c == '<' && i + 1 < len && stream[i + 1] == '<'
      depth = 1
      j = i + 2
      while j < len - 1 && depth > 0
        if stream[j, 2] == '<<'
          depth += 1
          j += 2
        elsif stream[j, 2] == '>>'
          depth -= 1
          j += 2
        else
          j += 1
        end
      end
      tokens << { type: :dict, value: stream[i...j] }
      i = j
      next
    end

    if c == '>' && i + 1 < len && stream[i + 1] == '>'
      i += 2
      next
    end

    if c == '['
      depth = 1
      j = i + 1
      while j < len && depth > 0
        depth += 1 if stream[j] == '['
        depth -= 1 if stream[j] == ']'
        j += 1
      end
      tokens << { type: :array, value: stream[i...j] }
      i = j
      next
    end

    if c == ']'
      i += 1
      next
    end

    if c == '/'
      j = i + 1
      while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
        j += 1
      end
      tokens << { type: :name, value: stream[i...j] }
      i = j
      next
    end

    j = i
    while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
      j += 1
    end

    if j == i
      i += 1
      next
    end

    word = stream[i...j]

    if word == 'BI'
      id_pos = stream.index(/\sID[\s\n\r]/, j)
      if id_pos
        ei_pos = stream.index(/[\s\n\r]EI(?=[\s\n\r\/\[<])/, id_pos + 3)
        if ei_pos
          i = ei_pos + 3
        else
          i = len
        end
      else
        i = j
      end
      next
    end

    if word =~ /\A[+-]?\d*\.?\d+\z/
      tokens << { type: :number, value: word.to_f }
    else
      tokens << { type: :operator, value: word }
    end
    i = j
  end

  tokens
end

def fast_tokenize(stream)
  parser = Parser.new([], nil)
  parser.send(:tokenize_content_stream, stream)
end

FIXTURES = [
  '',
  ' ',
  "\t\n\r\f\v\x00",
  '100 200 m 300 400 l S',
  '1.5 -2 +3.25 .5 m',
  '5. re', # "5." must remain an operator; "re" operator
  '/DeviceRGB CS 0 0 0 SC',
  '(Hello \(world\)) Tj',
  '<4142> Tj',
  '<< /Type /Page /Count 1 >>',
  '[1 2 3] d',
  '% comment only\n100 200 m',
  "q\n0 0 612 792 re\nW n\nQ",
  "BT /F1 12 Tf 100 700 Td (Title) Tj ET",
  "0.5 w 1 J 2 j [3 4] 0 d",
  "{ignored} 10 10 m",
  "BI /W 1 /H 1 /BPC 8 /CS /RGB ID \x00\x01\x02 EI q",
  # EI immediately followed by a name must keep the leading '/' (offset parity).
  "BI /W 1 ID \x00\x01 EI/Name Do",
].freeze

FIXTURES.each_with_index do |stream, idx|
  expected = regex_tokenize(stream)
  actual = fast_tokenize(stream)
  assert_equal(expected, actual, "fixture ##{idx} token stream mismatch")
end

# Explicit numeric classification parity
%w[0 1 12 .5 0.5 3.14 +1 -2 +0.25 -.5].each do |word|
  assert_true(Parser.new([], nil).send(:numeric_literal?, word),
              "#{word.inspect} should be numeric")
end
%w[5. . + - re m S DeviceRGB 1.2.3 1a].each do |word|
  assert_true(!Parser.new([], nil).send(:numeric_literal?, word),
              "#{word.inspect} should NOT be numeric")
end

puts "content_stream_tokenizer_test: #{$pass_count} passed, #{$failures.length} failed"
$failures.each { |f| puts "FAIL: #{f}" }
exit($failures.empty? ? 0 : 1)
