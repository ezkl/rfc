require 'nokogiri'
require 'delegate'
require 'forwardable'
require 'active_support/memoizable'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/array/grouping'
require 'erubis'

module RFC
  class NodeWrapper < DelegateClass(Nokogiri::XML::Node) 
    extend ActiveSupport::Memoizable

    # a reference to the main Document object
    attr_accessor :document

    attr_reader :classnames

    def initialize(node)
      super(node)
      @classnames = []
    end

    # wrap a sub-element
    def wrap(node, klass, *args)
      node = at(node) if String === node
      return nil if node.blank?
      element = klass.new(node, *args)
      element.document = self.document
      yield element if block_given?
      element
    end

    IGNORED_ELEMENTS = %w[iref cref]

    def element_names
      element_children.map(&:node_name) - IGNORED_ELEMENTS
    end

    def text_children
      children.select(&:text?)
    end

    def template_name
      self.class.name.demodulize.underscore
    end

    def all(path)
      search(path)
    end

    def text_at(path)
      node = at(path) and node.text
    end

    def scope(path)
      old_node = __getobj__
      node = at(path)
      if node then __setobj__(node)
      else raise "no node at #{path.inspect}"
      end

      if block_given?
        begin
          yield self
        ensure
          __setobj__(old_node)
        end
      else
        return self
      end
    end

    def self.define_predicate(name)
      define_method(:"#{name}?") { !self.send(name).blank? }
    end

    # TODO: remove memoization
    def self.method_added(name)
      if public_method_defined?(name) and not method_defined?(:"_unmemoized_#{name}") and
          name !~ /_unmemoized_|_memoizable$|^freeze$|[?!=]$/ and instance_method(name).arity.zero?
        memoize name
        define_predicate name unless method_defined?(:"#{name}?")
      end
    end
  end

  class Author < NodeWrapper
    def name
      self['fullname']
    end

    def role
      self['role']
    end

    def organization
      text_at 'organization'
    end

    def organization_short
      text_at './organization/@abbrev'
    end

    def email
      text_at './address/email'
    end

    def url
      text_at './address/uri'
    end
  end

  class Section < NodeWrapper
    attr_writer :title, :level
    attr_accessor :level

    def initialize(node, parent = nil)
      super node
      @title = nil
      @parent = parent
      self.level = @parent ? @parent.level + 1 : 2
    end

    def title
      @title || self['title']
    end

    def id
      # FIXME: ensure unique IDs
      self['anchor'].presence or title.parameterize
    end

    def elements
      element_children.each_with_object([]) do |node, all|
        case node.name
        when 'section'   then all << wrap(node, Section, self)
        when 'figure'    then all << wrap(node, Figure)
        when 'texttable' then all << wrap(node, Table)
        when 't'
          text = wrap(node, Text)
          in_definition_list = all.last.is_a? DefinitionList
          if text.definition? in_definition_list
            all << DefinitionList.new(document) unless in_definition_list
            all.last.add_element text
          else
            all << text
          end
        when 'iref', 'cref'
          # ignore
        else
          raise "unrecognized section-level node: #{node.name}"
        end
      end
    end

    def sections
      elements.select {|e| Section === e }
    end
  end

  class Xref < NodeWrapper
    def text
      super.presence || document.lookup_anchor(target) || target
    end

    def target
      self['target']
    end

    def href
      document.href_for(target)
    end
  end

  class Span < NodeWrapper
  end

  class Text < NodeWrapper
    def elements
      children.each_with_object([[]]) do |node, all|
        if node.element?
          case node.name
          when 'list'
            all << wrap(node, List) << []
          when 'vspace'
            # presentation element. ignore
          when 'xref', 'eref'
            all.last << wrap(node, Xref)
          when 'spanx'
            all.last << wrap(node, Span)
          when 'figure'
            all.last << wrap(node, Figure)
          when 'iref', 'cref'
            # ignore
          else
            $stderr.puts node.inspect if $-d
            raise "unrecognized text-level node: #{node.name}"
          end
        else
          all.last << node
        end
      end
    end

    def list?
      element_names == %w[list] and text_children.all?(&:blank?)
    end

    def list
      wrap('./list', List)
    end

    # The element is a definition list item when it contains only 1 text node
    # (definition title) and a list with a single item (definition description).
    #
    # However, if this element follows another definition item, then the inner
    # list can have multiple items.
    def definition? following_another = false
      element_names == %w[list] and title = definition_title and
        following_another || list.element_names == %w[t]
    end

    def definition_title
      nodes = text_children.select {|t| !t.blank? }
      if nodes.size == 1 and !nodes.first.text.strip.include?("\n")
        nodes.first
      end
    end

    def definition_description
      search('./list/t').map {|t| wrap(t, Text) }
    end
  end

  class List < NodeWrapper
    def elements
      element_children.map do |node|
        case node.name
        when 't' then wrap(node, Text)
        else
          raise "unrecognized list-level node: #{node.name}"
        end
      end
    end

    def style
      type = self['style'].presence || 'empty'
      type = 'alpha' if type == 'format (%C)'
      type
    end

    def note?
      first_element_child.text =~ /\A\s*Note:\s/
    end
  end

  class DefinitionList < Struct.new(:document, :elements)
    extend Forwardable
    def_delegator :elements, :<<, :add_element

    def initialize(doc, els = [])
      super(doc, els)
    end

    def template_name() 'definition_list' end
  end

  class Figure < NodeWrapper
    def id?
      self['anchor'].present?
    end

    def id
      self['anchor'].parameterize
    end

    def title
      self['title']
    end

    def text?
      text.present?
    end

    def text
      unindent text_at('./artwork')
    end

    def preamble
      wrap('./preamble', Text) { |t| t.classnames << 'preamble' }
    end

    def postamble
      wrap('./postamble', Text) { |t| t.classnames << 'postamble' }
    end

    protected

    def unindent(text)
      text = text.rstrip.gsub(/\r|\r\n/, "\n")
      lines = text.split("\n").reject(&:blank?)
      indentation = lines.map {|l| l.match(/^[ \t]*/)[0].to_s.size }.min
      text.gsub!(/^[ \t]{#{indentation}}/, '')
      text.sub!(/\A\s+\n/, '')
      text
    end
  end

  class Table < NodeWrapper
    def columns
      search('./ttcol')
    end

    def rows
      search('./c').map {|c| wrap(c, Text) }.in_groups_of(columns.size, false)
    end

    def preamble
      wrap('./preamble', Text) { |t| t.classnames << 'preamble' }
    end

    def postamble
      wrap('./postamble', Text) { |t| t.classnames << 'postamble' }
    end
  end

  class Reference < NodeWrapper
    def id?
      self['anchor'].present?
    end

    def id
      self['anchor'].parameterize
    end

    def title
      text_at 'title'
    end

    def url
      text_at './@target'
    end

    def month
      text_at './/date/@month'
    end

    def year
      text_at './/date/@year'
    end

    def series
      all('./seriesInfo').map {|s| "#{s['name']} #{s['value']}" }
    end
  end

  class Document < NodeWrapper
    attr_accessor :href_resolver

    def initialize(from)
      super Nokogiri::XML(from)
      scope '/rfc'
    end

    def document
      self
    end

    def number
      self['number']
    end

    CATEGORIES = {
      "std" => 'Standards-Track',
      "bcp" => 'Best Current Practices',
      "exp" => 'Experimental Protocol',
      "historic" => 'historic',
      "info" => 'Informational'
    }

    def category
      CATEGORIES[self['category'] || 'info']
    end

    def title
      text_at './front/title'
    end

    def short_title
      text_at './front/title/@abbrev'
    end

    def authors
      all('./front/author').map {|node| wrap(node, Author) }
    end

    def sections
      all('./middle/section').map {|node| wrap(node, Section) }
    end

    def back_sections
      all('./back/section').map {|node|
        wrap(node, Section) { |s|
          s.classnames << 'back'
          # indent them one level deeper since we're wrapping them
          # in an additional <section> element manually
          s.level = 3
        }
      }
    end

    def month
      text_at './front/date/@month'
    end

    def year
      text_at './front/date/@year'
    end

    def abstract
      wrap('./front/abstract', Section) do |s|
        s.title = 'Abstract'
        s.classnames << 'abstract'
      end
    end

    def keywords
      all('./front/keyword/text()').map(&:text)
    end

    # TODO: add memoization
    def anchor_map
      all('.//*[@anchor]').each_with_object({}) do |node, map|
        map[node['anchor']] = node
      end
    end

    def lookup_anchor(name)
      if node = anchor_map[name]
        if 'reference' == node.node_name
          if series = node.at('./seriesInfo[@name="RFC"]')
            "RFC #{series['value']}"
          elsif title = node.at('.//title')
            title.text
          end
        else
          node['title']
        end
      end
    end

    def href_for(target)
      if (target =~ /^[\w-]+:/) == 0
        target
      else
        href_resolver && href_resolver.call(target) ||
          ('#' + target.parameterize)
      end
    end

    def references
      all('./back/references/reference').map {|node| wrap(node, Reference) }
    end
  end

  module Helpers
    def section_title(section)
      "<h#{section.level}>#{h section.title}</h#{section.level}>"
    end

    def id_attribute
      id? ? %( id="#{h id}") : ''
    end

    def class_attribute(names = classnames)
      names = Array(names)
      names.any?? %[ class="#{h names.join(' ')}"] : ''
    end

    def render_inline(elements)
      # Array() doesn't work with text node, for some reason
      elements = [elements] unless Array === elements
      elements.map do |el|
        if el.is_a? Xref
          link_to el.text, el.href
        else
          h el.text
        end
      end.join('')
    end

    def h(str)
      Erubis::XmlHelper.escape_xml(str)
    end

    def link_to(text, href, classnames = nil)
      if href.present?
        %(<a href="#{h href}"#{class_attribute(classnames)}>#{h text}</a>)
      else
        h text
      end
    end

    def mail_to(email, text = email, classnames = nil)
      link_to text, "mailto:#{email}", classnames
    end

    def debug(obj)
      %(<pre>#{h obj.inspect}</pre>)
    end
  end

  module TemplateHelpers
    extend self
    def render(obj, template = obj.template_name)
      file = "templates/#{template}.erb"
      eruby = Erubis::Eruby.new File.read(file), filename: File.basename(file)
      context = SimpleDelegator.new(obj)
      context.extend Helpers
      context.extend TemplateHelpers
      eruby.evaluate(context)
    end
  end
end

if __FILE__ == $0
  rfc = RFC::Document.new ARGF

  include RFC::TemplateHelpers
  begin
    puts render(rfc)
  ensure
    $@.delete_if {|l| l.include? '/ruby/gems/' } if $@
  end
end
