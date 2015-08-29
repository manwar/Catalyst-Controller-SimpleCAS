package Catalyst::Controller::SimpleCAS::Role::TextTranscode;

use strict;
use warnings;

use MooseX::MethodAttributes::Role 0.29;
requires qw(Content fetch_content); #  <-- methods of Catalyst::Controller::SimpleCAS

use Encode;
use HTML::Encoding 'encoding_from_html_document', 'encoding_from_byte_order_mark';
use HTML::TokeParser::Simple;
use Try::Tiny;
use Email::MIME;
use Email::MIME::CreateHTML;
use Catalyst::Controller::SimpleCAS::CSS::Simple; #<-- hack/workaround CSS::Simple busted on CPAN
use String::Random;
use JSON;

use Catalyst::Controller::SimpleCAS::MimeUriResolver;

# FIXME - This is old and broken - file long gone from RapidApp ...
my $ISOLATE_CSS_RULE = ''; #'@import "/static/rapidapp/css/CssIsolation.css";';

# Backend action for Ext.ux.RapidApp.Plugin.HtmlEditor.LoadHtmlFile
sub transcode_html :Chained('base') :PathPart('texttranscode/transcode_html')  {
  my ($self, $c) = @_;
  
  my $upload = $c->req->upload('Filedata') or die "no upload object";

  my $src_text = $self->normaliaze_rich_content($c,$upload,$upload->filename);
  
  my $rct= $c->stash->{requestContentType};
  if ($rct eq 'JSON' || $rct eq 'text/x-rapidapp-form-response') {
    $c->stash->{json}= { success => \1, content => $src_text };
    return $c->forward('View::RapidApp::JSON');
  }
  
  # find out what encoding the user wants, defaulting to utf8
  my $dest_encoding= ($c->req->params->{dest_encoding} || 'utf-8');
  my $out_codec= Encode::find_encoding($dest_encoding) or die "Unsupported encoding: $dest_encoding";
  my $dest_octets= $out_codec->encode($src_text);
  
  # we need to set the charset here so that catalyst doesn't try to convert it further
  $c->res->content_type('text/html; charset='.$dest_encoding);
  return $c->res->body($dest_octets);
}

# Backend action for Ext.ux.RapidApp.Plugin.HtmlEditor.SaveMhtml
sub generate_mhtml_download :Chained('base') :PathPart('texttranscode/generate_mhtml_download') {
  my ($self, $c) = @_;
  die "No html content supplied" unless ($c->req->params->{html_enc});
  my $html = decode_json($c->req->params->{html_enc})->{data};

  # 'filename' param is optional and probably not supplied
  $html = $self->normaliaze_rich_content($c,$html,$c->req->params->{filename});
  
  my $filename = $self->get_strip_orig_filename(\$html) || 'content.mht';
  $filename =~ s/\"/\'/g; #<-- convert any " characters
  my $disposition = 'attachment;filename="' . $filename . '"';
  
  my $MIME = $self->html_to_mhtml($c,$html);

  $c->response->header( $_ => $MIME->header($_) ) for ($MIME->header_names);
  $c->response->header('Content-Disposition' => $disposition);
  return $c->res->body( $MIME->as_string );
}


# extracts filename previously embedded by normaliaze_rich_content in html comment
sub get_strip_orig_filename {
  my $self = shift;
  my $htmlref = shift;
  return undef unless (ref $htmlref);
  
  $$htmlref =~ /(\/\*----ORIGINAL_FILENAME:(.+)----\*\/)/;
  my $comment = $1 or return undef;
  my $filename = $2 or return undef;
  
  # strip comment:
  $$htmlref =~ s/\Q${comment}\E//;
  
  return  $filename;
}

sub html_to_mhtml {
  my $self = shift;
  my $c = shift;
  my $html = shift;
  
  my $style = $self->parse_html_get_styles(\$html,1);
  
  if($style) {
  
    # FIXME - this is broken:
    # strip isolate css import rule:
    $style =~ s/\Q$ISOLATE_CSS_RULE\E//g;
  
    my $Css = Catalyst::Controller::SimpleCAS::CSS::Simple->new;
    $Css->read({ css => $style });
    
    #scream_color(BLACK.ON_RED,$Css->get_selectors);
    
    # undo the cas selector wrap applied during Load Html:
    foreach my $selector ($Css->get_selectors) {
      my $new_selector = $selector;
      if($selector =~ /^\#cas\-selector\-wrap\-\w+$/){
        $new_selector = 'body';
      }
      else {
        my @parts = split(/\s+/,$selector);
        my $first = shift @parts;
        next unless ($first =~ /^\#cas\-selector\-wrap\-/);
        $new_selector = join(' ',@parts);
      }
      $Css->modify_selector({
        selector => $selector,
        new_selector => $new_selector
      });
    }
    
    $style = $Css->write;
  }
  
  # TODO/FIXME: remove RapidApp/TT dependency/entanglement
  $html = $c->template_render('templates/rapidapp/xhtml_document.tt',{
    style => $style, 
    body => $html
  });
  
  my $UriResolver = Catalyst::Controller::SimpleCAS::MimeUriResolver->new({
    Cas => $self,
    base => ''
  });
  
  my $MIME = Email::MIME->create_html(
    header => [], 
    body_attributes => { charset => 'UTF-8', encoding => 'quoted-printable' },
    body => encode('UTF-8', $html),
    resolver => $UriResolver
  );
  
  # Force wrap in a multipart/related
  return Email::MIME->create(
        attributes => {
            content_type => "multipart/related",
            disposition  => "attachment"
    },
    parts => [ $MIME ]
    ) unless ($MIME->subparts);
  
  return $MIME;
}


sub normaliaze_rich_content {
  my $self = shift;
  my $c = shift;
  my $src_octets = shift;
  my $filename = shift;
  
  my $upload;
  if(ref($src_octets)) {
    $upload = $src_octets;
    $src_octets = $upload->slurp;
  }
  
  my $content;
  
  # Try to determine what text encoding the file content came from, and then detect if it 
  # is MIME or HTML.
  #
  # Note that if the content came from a file upload/post an encode/decode phase happened 
  #   during the HTTP transfer of this file, but it should have been taken care of by Catalyst 
  #   and now we have the original file on disk in its native 8-bit encoding.

  # If MIME (MTHML):
  my $MIME = try{
    # This will frequently produce uninitialized value warnings from Email::Simple::Header,
    # and I haven't been able to figure out how to stop it
    Email::MIME->new($src_octets)
  };
  if($MIME && $MIME->subparts) {
    $content = $self->convert_from_mhtml($c,$MIME);
  }
  # If HTML or binary:
  else {
    if(!$upload || $upload->type =~ /^text/){
      my $src_encoding= encoding_from_html_document($src_octets) || 'utf-8';
      my $in_codec= Encode::find_encoding($src_encoding) or die "Unsupported encoding: $src_encoding";
      $content = (utf8::is_utf8($src_octets)) ? $src_octets : $in_codec->decode($src_octets);
    }
    # Binary
    else {
      my $checksum = $self->Store->add_content_file_mv($upload->tempname) or die "Failed to add content";
      my $Content = $self->Content($checksum,$upload->filename);
      return $Content->imglink if ($Content->imglink);
      return $Content->filelink;
    }
  }
  # TODO: Detect other content types and add fallback logic
  
  $content = $self->parse_html_get_style_body(\$content);
  $self->convert_data_uri_scheme_links($c,\$content);
  
  # Use style tags just as a safe place to store the original filename
  # (switched to this after having issues with html comments)
  $content = '<style>/*----ORIGINAL_FILENAME:' .
    $filename .
  '----*/</style>' . "\n" . $content if ($filename);

  return $content;
}


sub convert_from_mhtml {
  my $self = shift;
  my $c = shift;
  my $MIME = shift;

  my ($SubPart) = $MIME->subparts or return;
  
  ## -- Check for and remove extra outer MIME wrapper (exists in actual MIME EMails):
  $MIME = $SubPart if (
    $SubPart->content_type &&
    $SubPart->content_type =~ /multipart\/related/
  );
  ## --
  
  my ($MainPart) = $MIME->subparts or return;

  ## ------
  ## New: throw the kitchen sink at trying to figure out the charset/encoding
  ##
  ## This solves the long-standing problem where MHT files saved by Word 2010
  ## would load garbled. These files are encoded as 'UTF-16LE', and the system
  ## is not able to realize this out of the box (I think because it lists the
  ## the charset ambiguously as ' charset="unicode" ' in the Content-Type
  ## MIME header, but I'm no expert on Unicode). Below we're basically trying 
  ## all of the functions of HTML::Encoding until we find one that gives us
  ## an answer, and if we do get an answer, we apply it to the MIME object before
  ## calling ->body_str() which will then use it to decode to text.
  ##
  my $decoded = $MainPart->body; # <-- decodes from base64 (or whatever) to *bytes*

  my $char_set =
    HTML::Encoding::encoding_from_html_document   ($decoded) ||
    HTML::Encoding::encoding_from_byte_order_mark ($decoded) ||
    HTML::Encoding::encoding_from_meta_element    ($decoded) ||
    HTML::Encoding::xml_declaration_from_octets   ($decoded) ||
    HTML::Encoding::encoding_from_first_chars     ($decoded) ||
    HTML::Encoding::encoding_from_xml_declaration ($decoded) ||
    HTML::Encoding::encoding_from_content_type    ($decoded) ||
    HTML::Encoding::encoding_from_xml_document    ($decoded);

  $MainPart->charset_set( $char_set ) if ($char_set);
  ## ------

  my $html = $MainPart->body_str; # <-- decodes to text using the character_set

  my $base_path = $self->parse_html_base_href(\$html) || $self->get_mime_part_base_path($MainPart);
  
  my %ndx = ();
  $MIME->walk_parts(sub{ 
    my $Part = shift;
    return if ($Part == $MIME || $Part == $MainPart); #<-- ignore the outer and main/body parts
    
    my $content_id = $Part->header('Content-ID');
    if ($content_id) {
      $ndx{'cid:' . $content_id} = $Part;
      $content_id =~ s/^\<//;
      $content_id =~ s/\>$//;
      $ndx{'cid:' . $content_id} = $Part;
    }
    
    my $content_location = $Part->header('Content-Location');
    if($content_location) {
      $ndx{$content_location} = $Part;
      if($base_path) {
        $content_location =~ s/^\Q$base_path\E//;
        $ndx{$content_location} = $Part;
      }
    }
  });
  
  $self->convert_mhtml_links_parts($c,\$html,\%ndx);
  return $html;
}

# Try to extract the 'body' from html to prevent causing DOM/parsing issues on the client side
sub parse_html_get_style_body {
  my $self = shift;
  my $htmlref = shift;
  
  my $body = $self->parse_html_get_body($htmlref) or return $$htmlref;
  my $style = $self->parse_html_get_styles($htmlref);
  
  my $auto_css_pre = 'cas-selector-wrap-';
  my $auto_css_id = $auto_css_pre . String::Random->new->randregex('[a-z0-9]{8}');
  
  if($style) {
    my $Css = Catalyst::Controller::SimpleCAS::CSS::Simple->new;
    $Css->read({ css => $style });
    
    #scream_color(BLACK.ON_RED,$Css->get_selectors);
    
    foreach my $selector ($Css->get_selectors) {
      my @parts = split(/\s+/,$selector);
      # strip selector wrap from previous content processing (when the user imports + 
      # exports + imports multiple times)
      shift @parts if ($parts[0] =~ /^\#${auto_css_pre}/);
      unshift @parts, '#' . $auto_css_id;
      pop @parts if (lc($selector) eq 'body'); #<-- any 'body' selectors are replaced by the new div wrap below
      
      $Css->modify_selector({
        selector => $selector,
        new_selector => join(' ',@parts)
      });
    }
    
    $style = $Css->write;
  }

  if ($style) {
    # minify:
    $style =~ s/\r?\n/ /gm;
    $style =~ s/\s+/ /gm;
    $style = "\n<style type=\"text/css\">\n$style\n</style>";
  }
  
  $style ||= '';
  $style = "\n" .  '<style type="text/css">' . "\n" .
    "   $ISOLATE_CSS_RULE\n" .
    '</style>' . $style . "\n";

  return '<div class="isolate" id="' . $auto_css_id . '">' . "\n" .
    $body . "\n" . 
  '</div>' . "\n$style";    
}


# Try to extract the 'body' from html to prevent causing DOM/parsing issues on the client side
# Also strip html comments
sub parse_html_get_body {
  my $self = shift;
  my $htmlref = shift;
  my $parser = HTML::TokeParser::Simple->new($htmlref);
  my $in_body = 0;
  my $inner = '';
  while (my $tag = $parser->get_token) {
    last if ($in_body && $tag->is_end_tag('body'));
    $inner .= $tag->as_is if ($in_body && !$tag->is_comment);
    $in_body = 1 if ($tag->is_start_tag('body'));
  };
  return undef if ($inner eq '');
  return $inner;
}

sub parse_html_get_styles {
  my $self = shift;
  my $htmlref = shift;
  my $strip = shift;
  my $parser = HTML::TokeParser::Simple->new($htmlref);
  my $in_style = 0;
  my $styles = '';
  my $newhtml = '';
  while (my $tag = $parser->get_token) {
    if ($tag->is_end_tag('style')) {
      $in_style = 0;
      next;
    }
    $styles .= $tag->as_is and next if ($in_style);
    if ($tag->is_start_tag('style')) {
      $in_style = 1; 
      next;
    }
    $newhtml .= $tag->as_is if($strip && !$tag->is_tag('style'));
  };
  return undef if ($styles eq '');
  
  $$htmlref = $newhtml if ($strip);
  
  # Pull out html comment characters, ignored in css, but can interfere with CSS::Simple (rare cases)
  $styles =~ s/\<\!\-\-//g;
  $styles =~ s/\-\-\>//g;
  
  return $styles;
}



# Extracts the base file path from the 'base' tag of the MHTML content
sub parse_html_base_href {
  my $self = shift;
  my $htmlref = shift;
  my $parser = HTML::TokeParser::Simple->new($htmlref);
  while (my $tag = $parser->get_tag) {
    if($tag->is_tag('base')){
      my $url = $tag->get_attr('href') or next;
      return $url;
    }
  };
  return undef;
}

# alternative method to identify a base path from a Mime Part
sub get_mime_part_base_path {
  my $self = shift;
  my $Part = shift;
  
  my $content_location = $Part->header('Content-Location') or return undef;
  my @parts = split(/\//,$content_location);
  my $filename = pop @parts;
  my $path = join('/',@parts) . '/';
  
  return $path;
}


sub convert_mhtml_links_parts {
  my $self = shift;
  my $c = shift;
  my $htmlref = shift;
  my $part_ndx = shift;
  
  die "convert_mhtml_links_parts(): Invalid arguments!!" unless (ref $part_ndx eq 'HASH');
  
  my $parser = HTML::TokeParser::Simple->new($htmlref);
  
  my $substitutions = {};
  
  while (my $tag = $parser->get_tag) {
    next if($tag->is_tag('base')); #<-- skip the 'base' tag which we parsed earlier
    for my $attr (qw(src href)){
      my $url = $tag->get_attr($attr) or next;
      my $Part = $part_ndx->{$url} or next;
      my $cas_url = $self->mime_part_to_cas_url($c,$Part) or next;
      
      my $as_is = $tag->as_is;
      $tag->set_attr( $attr => $cas_url );
      $substitutions->{$as_is} = $tag->as_is;
    }
  }
  
  foreach my $find (keys %$substitutions) {
    my $replace = $substitutions->{$find};
    $$htmlref =~ s/\Q$find\E/$replace/gm;
  }
}



# See http://en.wikipedia.org/wiki/Data_URI_scheme
sub convert_data_uri_scheme_links {
  my $self = shift;
  my $c = shift;
  my $htmlref = shift;
  
  my $parser = HTML::TokeParser::Simple->new($htmlref);
  
  my $substitutions = {};
  
  while (my $tag = $parser->get_tag) {
  
    my $attr;
    if($tag->is_tag('img')) {
      $attr = 'src';
    }
    elsif($tag->is_tag('a')) {
      $attr = 'href';
    }
    else {
      next;
    }
    
    my $url = $tag->get_attr($attr) or next;
    
    # Support the special case where the src value is literal base64 data:
    if ($url =~ /^data:/) {
      my $newurl = $self->embedded_src_data_to_url($c,$url);
      $substitutions->{$url} = $newurl if ($newurl);
    }
  }
  
  foreach my $find (keys %$substitutions) {
    my $replace = $substitutions->{$find};
    $$htmlref =~ s/\Q$find\E/$replace/gm;
  }
}

sub embedded_src_data_to_url {
  my $self = shift;
  my $c = shift;
  my $url = shift;
  
  my ($pre,$content_type,$encoding,$base64_data) = split(/[\:\;\,]/,$url);
  
  # we only know how to handle base64 currently:
  return undef unless (lc($encoding) eq 'base64');
  
  my $checksum = try{$self->Store->add_content_base64($base64_data)}
    or return undef;
  
  # This is RapidApp-specific
  my $pfx = $c->can('mount_url') ? $c->mount_url || '' : '';
  
  return join('/',$pfx,
    $self->action_namespace($c),
    'fetch_content', $checksum
  );
}

sub mime_part_to_cas_url {
  my $self = shift;
  my $c = shift;
  my $Part = shift;
  
  my $data = $Part->body;
  my $filename = $Part->filename(1);
  my $checksum = $self->Store->add_content($data) or return undef;
  
  # This is RapidApp-specific
  my $pfx = $c->can('mount_url') ? $c->mount_url || '' : '';
  
  return join('/',$pfx,
    $self->action_namespace($c),
    'fetch_content', $checksum, $filename
  );
}

1;

__END__

=head1 NAME

Catalyst::Controller::SimpleCAS::Role::TextTranscode - Addl MHTML methods for SimpleCAS

=head1 SYNOPSIS

 use Catalyst::Controller::SimpleCAS;
 ...

=head1 DESCRIPTION

This is a Role which adds extra methods and functionality to L<Catalyst::Controller::SimpleCAS>.
This role is automatically loaded into the main controller class. The reason that this exists and
is structured this way is for historical reasons and will likely be refactored later.


=head1 PUBLIC ACTIONS

=head2 transcode_html (texttranscode/transcode_html)

=head2 generate_mhtml_download  (texttranscode/generate_mhtml_download)

=head1 METHODS

=head2 convert_data_uri_scheme_links

=head2 convert_from_mhtml

=head2 convert_mhtml_links_parts

=head2 embedded_src_data_to_url

=head2 get_mime_part_base_path

=head2 get_strip_orig_filename

=head2 html_to_mhtml

=head2 mime_part_to_cas_url

=head2 normaliaze_rich_content

=head2 parse_html_base_href

=head2 parse_html_get_body

=head2 parse_html_get_style_body

=head2 parse_html_get_styles

=head1 SEE ALSO

=over

=item *

L<Catalyst::Controller::SimpleCAS>

=back

=head1 AUTHOR

Henry Van Styn <vanstyn@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by IntelliTree Solutions llc.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut