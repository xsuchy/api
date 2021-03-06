#
#   mod_perl handler, gudeposts, part of openstreetmap.cz
#   Copyright (C) 2015, 2016 Michal Grezl
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software Foundation,
#   Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
#

package Guidepost::Table;

use utf8;

use Apache2::Reload;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::URI ();

use APR::URI ();
use APR::Brigade ();
use APR::Bucket ();
use Apache2::Filter ();

#use Apache2::Const -compile => qw(MODE_READBYTES);
#use APR::Const    -compile => qw(SUCCESS BLOCK_READ);

use constant IOBUFSIZE => 8192;
use Apache2::Connection ();
use Apache2::RequestRec ();

use APR::Const -compile => qw(URI_UNP_REVEALPASSWORD);
use Apache2::Const -compile => qw(OK SERVER_ERROR NOT_FOUND);

use DBI;

use Data::Dumper;
use Scalar::Util qw(looks_like_number);

use Geo::JSON;
use Geo::JSON::Point;
use Geo::JSON::Feature;
use Geo::JSON::FeatureCollection;

use Sys::Syslog;                        # all except setlogsock()
use HTML::Entities;

use File::Copy;
#use Encode::decode_utf8();
use Encode;

#binmode STDIN, ':utf8';
#binmode STDOUT, ':utf8';

use Net::Subnet;

my $dbh;
my $BBOX = 0;
my $LIMIT = 0;
my $minlon;
my $minlat;
my $maxlon;
my $maxlat;
my $error_result;

################################################################################
sub handler
################################################################################
{
  $BBOX = 0;
  $LIMIT = 0;

  $r = shift;
  openlog('guidepostapi', 'cons,pid', 'user');

  if (&check_ban()) {
    syslog('info', 'access denied:' . $r->connection->remote_ip);
    return Apache2::Const::OK;
  }

#  syslog('info', 'start method:'. $r->method());

  my $uri = $r->uri;      # what does the URI (URL) look like ?
  &parse_query_string($r);
  &parse_post_data($r);

  if (exists $get_data{bbox}) {
    &parse_bbox($get_data{bbox});
  }

  if (exists $get_data{limit}) {
    $LIMIT = $get_data{limit};
  }

  if (!exists $get_data{output} or $get_data{output} eq "html") {
    $OUTPUT_FORMAT = "html";
    $r->content_type('text/html; charset=utf-8');
  } elsif ($get_data{output} eq "geojson") {
    $OUTPUT_FORMAT = "geojson";
#    $r->content_type('application/json; charset=utf-8');
    $r->content_type('text/plain; charset=utf-8');
#    $r->content_type('text/html; charset=utf-8');
  } elsif ($get_data{output} eq "kml") {
    $OUTPUT_FORMAT = "kml";
  }

  $r->no_cache(1);

  &connect_db();

  @uri_components = split("/", $uri);

  foreach $text (@uri_components) {
    $text =~ s/[^A-Za-z0-9ěščřžýáíéĚŠČŘŽÝÁÍÉůúŮÚ.:]//g;
  }

  $error_result = Apache2::Const::OK;

  my $api_request = $uri_components[2];
  syslog('info', "request $api_request, method " . $r->method());


  if ($uri =~ "table\/all") {
    &output_all();
  } elsif ($uri =~ /goodbye/) {
    &say_goodbye($r);
  } elsif ($uri =~ "/table/count") {
    print &get_gp_count();
  } elsif ($uri =~ "/table/get") {
    &table_get($uri_components[3], $uri_components[4]);
  } elsif ($uri =~ "/table/leaderboard") {
    &leaderboard();
  } elsif ($uri =~ "/table/ref") {
    my $joined_ref = substr(join('/', @uri_components[3 .. scalar @uri_components]), 0, -1);
    &show_by_ref($joined_ref);
  } elsif ($uri =~ "/table/id") {
    &show_by_id($uri_components[3]);
  } elsif ($uri =~ "/table/name") {
    &show_by_name($uri_components[3]);
  } elsif ($uri =~ "/table/note") {
    &show_by($uri_components[3],"note");
  } elsif ($uri =~ "/table/setbyid") {
    &set_by_id($post_data{id}, $post_data{value});
  } elsif ($uri =~ "isedited") {
    #/isedited/ref/id
    &is_edited($uri_components[3], $uri_components[4]);
  } elsif ($uri =~ "isdeleted") {
    &is_deleted($uri_components[3]);
  } elsif ($uri =~ "/table/approve") {
    &approve_edit($uri_components[3]);
  } elsif ($uri =~ "/table/reject") {
    &reject_edit($uri_components[3]);
  } elsif ($uri =~ "/table/review") {
    &review_form();
  } elsif ($uri =~ "/table/delete") {
    &delete_id($uri_components[3]);
  } elsif ($uri =~ "/table/remove") {
    &remove($uri_components[3]);
  } elsif ($uri =~ "/table/close") {
#default output must be geojson
#params: $get_data{lat}, $get_data{lon}, $get_data{distance}, $get_data{limit}
    &get_nearby($get_data{lat}, $get_data{lon}, $get_data{distance}, $get_data{limit});
  } elsif ($uri =~ "/table/tags/delete") {
    &delete_tags($uri_components[4], $uri_components[5]);
  } elsif ($uri =~ "/table/tags/add") {
    #id,val
    &add_tags($uri_components[4], $uri_components[5]);
  } elsif ($uri =~ "/table/tags") {
    my $out = &get_tags($uri_components[3]);
    $r->print($out);
  }
#Dumper(\%ENV);
#    connection_info($r->connection);
#    $r->send_http_header;   # Now send the http headers.


  $dbh->disconnect;

  syslog('info', 'handler result:' . $error_result);

  if ($error_result) {
    if ($error_result == 400) {error_400();}
    if ($error_result == 404) {error_404();}
    if ($error_result == 500) {error_500();}
    $r->status($error_result);
  }

  closelog();
  return Apache2::Const::OK;
}

################################################################################
sub error_400()
################################################################################
{
  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>400 Bad request</title>
</head><body>
<h1>This is bad</h1>
<p>and you should feel bad</p>
<hr>
<address>openstreetmap.cz/2 Ulramegasuperdupercool/0.0.1 Server at api.openstreetmap.cz Port 80</address>
</body></html>
');
}

################################################################################
sub error_404()
################################################################################
{
  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>404 Not Found</title>
</head><body>
<h1>Not Found</h1>
<p>We don\'t know nothing about this</p>
<hr>
<address>openstreetmap.cz/2 Ulramegasuperdupercool/0.0.1 Server at api.openstreetmap.cz Port 80</address>
</body></html>
');
}

################################################################################
sub error_500()
################################################################################
{
  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>500 Boo Boo</title>
</head><body>
<h1>YAY!</h1>
<p>We don\'t know nothing about this</p>
<hr>
<address>openstreetmap.cz/2 Ulramegasuperdupercool/0.0.1 Server at api.openstreetmap.cz Port 80</address>
</body></html>
');
}

################################################################################
sub output_all()
################################################################################
{
  my $query = "select * from guidepost";
  if ($BBOX) {
    $query .= " where " . &add_bbox();
  }
  if ($LIMIT) {
    $query .= " limit " . $LIMIT;
  }
  &output_data($query);
}

################################################################################
sub check_ban()
################################################################################
{
  my $banned = subnet_matcher qw(
    66.249.69.0/24
    66.249.64.0/24
  );
#doubrava  185.93.61.0/24
  return ($banned->($r->connection->remote_ip));
}

################################################################################
sub check_privileged_access()
################################################################################
{
  my $ok = subnet_matcher qw(
    185.93.61.1/32
    195.113.123.0/24
  );
  if ($ok->($r->connection->remote_ip)) {
    return 1;
  } else {
    syslog('info', 'privileged access denied:' . $r->connection->remote_ip);
    return 0;
  }
}

################################################################################
sub connection_info
################################################################################
{
  my ($c) = @_;
  print $c->id();
  print $c->local_addr();
  print $c->remote_addr();
  print $c->local_host();
  print $c->get_remote_host();
  print $c->remote_host();
  print $c->local_ip();
  print $c->remote_ip();
}

################################################################################
sub rrr
################################################################################
{
   $parsed_uri = $r->parsed_uri();

    print "s".$parsed_uri->scheme;print "<br>";
    print "u".$parsed_uri->user;print "<br>";
    print "pw".$parsed_uri->password;print "<br>";
    print "h".$parsed_uri->hostname;print "<br>";
    print "pt".$parsed_uri->port;print "<br>";
    print "pa".$parsed_uri->path;print "<br>";
    print "rpa".$parsed_uri->rpath;print "<br>";
    print "q".$parsed_uri->query;print "<br>";
    print "f".$parsed_uri->fragment;print "<br>";
    print "<hr>\n";
 }

################################################################################
sub say_goodbye
################################################################################
{
  my $r = shift;
  print $r->args;

  &parse_query_string($r);

  foreach (sort keys %get_data) {
    print "$_ : $get_data{$_}\n";
  }
}

################################################################################
sub smartdecode
################################################################################
{
  use URI::Escape qw( uri_unescape );
  my $x = my $y = uri_unescape($_[0]);
  return $x if utf8::decode($x);
  return $y;
}

################################################################################
sub parse_query_string
################################################################################
{
  my $r = shift;

  %get_data = map { split("=",$_) } split(/&/, $r->args);

  #sanitize
  foreach (sort keys %get_data) {
    $get_data{$_} =~ s/\%2C/,/g;
    $get_data{$_} =~ s/\%2F/\//g;
    if (lc $_ eq "bbox" or lc $_ eq "lat" or lc $_ eq "lon" ) {
      $get_data{$_} =~ s/[^A-Za-z0-9\.,-]//g;
    } elsif ($_ =~ /output/i ) {
      $get_data{$_} =~ s/[^A-Za-z0-9\.,-\/]//g;
    } else {
      $get_data{$_} =~ s/[^A-Za-z0-9 ]//g;
    }
#    syslog('info', "getdata " . $_ . "=" . $get_data{$_});
  }
}

################################################################################
sub parse_post_data
################################################################################
{
  my $r = shift;

  $raw_data = decode_entities(&read_post($r));

  %post_data = map { split("=",$_) } split(/&/, $raw_data);

  #sanitize
  foreach (sort keys %post_data) {
    syslog('info', "postdata before " . $_ . "=" . $post_data{$_});
    $post_data{$_} = &smartdecode($post_data{$_});
    $post_data{$_} =~ s/\+/ /g;
    $post_data{$_} =~ s/\%2F/\//g;
    $post_data{$_} =~ s/\%2C/,/g;
    syslog('info', "postdata after decode " . $_ . "=" . $post_data{$_});

    if (lc $_ eq "id" ) {
      $post_data{$_} =~ s/[^A-Za-z0-9_\/]//g;
    } elsif (lc $_ eq "value" ) {
      syslog('info',"value");
      $post_data{$_} =~ s/[^A-Za-z0-9_ \p{IsLatin}\/,]//g;
    } else {
      $post_data{$_} =~ s/[^A-Za-z0-9 ]//g;
    }
#    syslog('info', "postdata " . $_ . "=" . $post_data{$_});
  }
}

################################################################################
sub connect_db
################################################################################
{
  my $dbfile = '/var/www/mapy/guidepost';

#  $dbh = DBI->connect( "dbi:SQLite:$dbfile" );

  $dbh = DBI->connect("dbi:SQLite:$dbfile", "", "",
    {
#       RaiseError     => 1,
       sqlite_unicode => 1,
    }
  );


  if (!$dbh) {
#    &debuglog("db failed","Cannot connect: ".$DBI::errstr);
    die;
  }
#  my $sql = qq{SET NAMES 'utf8';};
#  $dbh->do($sql);
}

################################################################################
sub parse_bbox
################################################################################
{
  my $b = shift;
#BBox=-20,-40,60,40

  #print $b;

  @bbox = split(",", $b);
  $minlon = $bbox[0];
  $minlat = $bbox[1];
  $maxlon = $bbox[2];
  $maxlat = $bbox[3];
  $BBOX = 1;
}

################################################################################
sub add_bbox
################################################################################
{
  if ($BBOX) {
    return "lat < $maxlat and lat > $minlat and lon < $maxlon and lon > $minlon";
  }
}

################################################################################
sub show_by_ref
################################################################################
{
  my $ref = shift;
  &show_by($ref,'ref');
}

################################################################################
sub show_by_id
################################################################################
{
  my $id = shift;
  &show_by($id,'id');
}

################################################################################
sub show_by_name
################################################################################
{
  my $name = shift;
  &show_by($name, "attribution");
}

################################################################################
sub show_by
################################################################################
{
  my ($val, $what) = @_;

  syslog('info', "show_by($val, $what)");

  my $query = "select * from guidepost where $what='$val'";

  if ($BBOX) {
    $query .= " and ".&add_bbox();
  }

  $error_result = &output_data($query);
}


################################################################################
sub output_data
################################################################################
{
  my ($query) = @_;
  my $ret;

  syslog("info", "output_data query:" . $query);

  if ($OUTPUT_FORMAT eq "html") {
    $ret = output_html($query);
  } elsif ($OUTPUT_FORMAT eq "geojson") {
    $ret = output_geojson($query);
  } elsif ($OUTPUT_FORMAT eq "kml") {
    $ret = output_kml($query);
  }

  syslog("info", "output_data result:" . $ret);

  return $ret;
}

################################################################################
sub output_kml
################################################################################
{
  return Apache2::Const::SERVER_ERROR;
}

################################################################################
sub output_html
################################################################################
{
  my ($query) = @_;

#<link rel="stylesheet" href="https://goodies.pixabay.com/jquery/tag-editor/jquery.tag-editor.css">
    @s = (
      "http://code.jquery.com/jquery-1.11.3.min.js", 
      "http://www.appelsiini.net/download/jquery.jeditable.mini.js",
      "http://api.openstreetmap.cz/wheelzoom.js",
      "https://code.jquery.com/ui/1.10.2/jquery-ui.min.js",
      "https://goodies.pixabay.com/jquery/tag-editor/jquery.caret.min.js",
      "https://goodies.pixabay.com/jquery/tag-editor/jquery.tag-editor.js",
    );
    @l = (
      "https://goodies.pixabay.com/jquery/tag-editor/jquery.tag-editor.css"
    );

  my $out = &page_header(\@s,\@l);

  $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    syslog("info", "output_html dberror" . $DBI::errstr);
    $out = "DB error";
    print $out;
    return;
  }

  my $num_elements = @$res;

  if (!$num_elements) {
    return Apache2::Const::NOT_FOUND;
  }

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @$row;
    $out .= &gp_line($id, $lat, $lon, $url, $name, $attribution, $ref, $note);
    $out .= "\n";
  }

  $out .= "<script>wheelzoom(document.querySelectorAll('img'));</script>";
  $out .= &init_inplace_edit();
  $out .= &page_footer();

  $r->print($out);

  return Apache2::Const::OK;
}

################################################################################
sub output_geojson
################################################################################
{
  use utf8;

  my ($query) = @_;

  my $pt;
  my $ft;
  my @feature_objects;

  $res = $dbh->selectall_arrayref($query);

  if (!$res) {
    print $DBI::errstr;
    return Apache2::Const::SERVER_ERROR;
  }

  my $num_elements = @$res;

  if (!$num_elements) {
    return Apache2::Const::NOT_FOUND;
  }

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @$row;

    my $fixed_lat = looks_like_number($lat) ? $lat : 0;
    my $fixed_lon = looks_like_number($lon) ? $lon : 0;

    $pt = Geo::JSON::Point->new({
      coordinates => [$fixed_lon, $fixed_lat],
      properties => ["prop0", "value0"],
    });

    my %properties = (
      'id' => $id,
      'url' => $url,
      'attribution' => $attribution,
      'name' => $name,
      'ref' => $ref,
      'note' => $note,
    );

    $ft = Geo::JSON::Feature->new({
      geometry   => $pt,
      properties => \%properties,
    });

    push @feature_objects, $ft;
  }


  my $fcol = Geo::JSON::FeatureCollection->new({
     features => \@feature_objects,
  });

  #print $fcol->to_json."\n";
  $r->print($fcol->to_json."\n");

  return Apache2::Const::OK;
}


################################################################################
sub table_get
################################################################################
{
  my ($pf, $pt) = @_;

  my $out = "";

  my $from_gp = looks_like_number($pf) ? $pf : 0;
  my $to_gp = looks_like_number($pt) ? $pt : 0;
  $out .= "<h1>from ($pf $pt) ($from_gp) ($to_gp)</h1><hr>";

  my $query = "select * from guidepost LIMIT " . ($to_gp - $from_gp) . " OFFSET $from_gp";
  $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    syslog("info", "output_html dberror" . $DBI::errstr);
    $out = "DB error";
  }

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @$row;
    $out .= &gp_line($id, $lat, $lon, $url, $name, $attribution, $ref, $note);
    $out .=  "</p>\n";
  }

  $out .=  &init_inplace_edit();
  $out .=  "<script>wheelzoom(document.querySelectorAll('img'));</script>";

  $r->print($out);
}

################################################################################
sub play_badge()
################################################################################
{
return '<a href="https://play.google.com/store/apps/details?id=org.walley.guidepost">
<img alt="Android app on Google Play" width="100px"
 src="https://play.google.com/intl/en_us/badges/images/generic/en-play-badge.png">
</a>';
}

################################################################################
sub leaderboard
################################################################################
{
  my $out = "";

  $out .= &page_header();
  $out .= "<h1>Leaderboard</h1>";

  my $query = "select attribution, count (*) as num from guidepost group by attribution order by num desc";
  my $pos = 1;

  $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    $out .= $DBI::errstr;
  }

  $out .= &play_badge();

  $out .= "<table>\n";
  $out .= "<tr><th>position</th><th>name</th><th>count</th></tr>";
  foreach my $row (@$res) {
    my ($name, $count) = @$row;
    $out .= "<tr><td>" . $pos++. "</td><td>$name</td><td>$count</td></tr>";
  }
  $out .= "</table>\n";
  $out .= &page_footer();

  $r->print($out);

}

################################################################################
sub init_inplace_edit()
################################################################################
{
  my $url = "http://api.openstreetmap.cz/table/setbyid";
  my $out = "";

  $out .= "<script>\n";
  $out .= "  \$('.edit').editable('" . $url. "', {\n";
  $out .= "     indicator   : 'Saving...',\n";
  $out .= "     cancel      : 'Cancel',\n";
  $out .= "     submit      : 'OK',\n";
  $out .= "     event       : 'click',\n";
  $out .= "     width       : 100,\n";
  $out .= "     select      : true,\n";
  $out .= "     placeholder : '" . &t("edited") . "',\n";
  $out .= "     tooltip     : '" . &t("Click to edit...") . "',\n";
  $out .= " 
  callback : function(value, settings) {
    console.log(this);
    console.log(value);
    console.log(settings);
  }
  ";
  $out .= "  });\n";
  $out .= "</script>\n";

  return $out;
}



################################################################################
sub maplinks()
################################################################################
{
  my ($lat, $lon) = @_;
  my $out = "<!-- maplinks -->";
#  $out .=  "<span class='maplinks'>\n";
  $out .=  "<span>\n";
  $out .=  "<ul>\n";
#  $out .=  "<li><a href='http://maps.yahoo.com/#mvt=m&lat=$lat&lon=$lon&mag=6&q1=$lat,$lon'>Yahoo</a>";
  $out .=  "<li><a href='http://www.openstreetmap.cz/?mlat=$lat&mlon=$lon&zoom=16#map=16/$lat/$lon'>osm.cz</a>";
  $out .=  "<li><a href='http://www.openstreetmap.org/?mlat=$lat&mlon=$lon&zoom=16#map=16/$lat/$lon'>OSM</a>";
  $out .=  "<li><a href='https://maps.google.com/maps?ll=$lat,$lon&q=loc:$lat,$lon&hl=en&t=m&z=16'>Google</a>";
  $out .=  "<li><a href='http://www.bing.com/maps/?v=2&cp=$lat~$lon&style=r&lvl=16'>Bing</a>";
  $out .=  "<li><a href='http://www.mapy.cz/?st=search&fr=loc:".$lat."N ".$lon."E'>Mapy.cz</a>";
  $out .=  "<li><a href='http://mapy.idnes.cz/#pos=".$lat."P".$lon."P13'>idnes.cz</a>";
  $out .=  "</ul>\n";
  $out .=  "</span>\n";
  
  return $out;
}


################################################################################
sub static_map()
################################################################################
{
#minimap smallmap
  my ($lat, $lon) = @_;
  my $out = "<!-- static map -->";

  $static_map = "http://open.mapquestapi.com/staticmap/v4/getmap?key=Fmjtd%7Cluu22qu1nu%2Cbw%3Do5-h6b2h&center=$lat,$lon&zoom=15&size=200,200&type=map&imagetype=png&pois=x,$lat,$lon";
#  $out .=  "<img src='http://staticmap.openstreetmap.de/staticmap.php?center=$lat,$lon&zoom=14&size=200x200&maptype=mapnik&markers=$lat,$lon,lightblue1' />";

#  $out .=  "<span class='staticmap'>\n";
#  $out .=  "<span>\n";
  $out .=  "<img class='zoom' src='".$static_map."'/>";
#  $out .=  "</span>\n";

  return $out;
}


################################################################################
sub delete_button
################################################################################
{
  my $ret = "";
  $ret .= "<span title='" . &t("remove_picture") ."'>";
  $ret .= "delete <img src='http://api.openstreetmap.cz/img/delete.png' width=16 height=16>";
  $ret .= "</span>";
  return $ret;
}

################################################################################
sub id_stuff
################################################################################
{
  ($id) = @_;
  my $ret = "<!-- is stuff -->";
  $ret .= "<div class='Table'>\n";
  $ret .= "<div class='Row'>\n";
  $ret .= "<div class='Cell'>\n";
  $ret .= "<h2>$id</h2>\n";
  $ret .= "</div>\n";
  $ret .= "</div>\n";
  $ret .= "<div class='Row'>\n";
  $ret .= "<div class='Cell'>\n";

  $ret .= "<div id='remove$id'>\n";
  $ret .= &delete_button();
  $ret .= "</div>";


  $ret .= "</div>\n";
  $ret .= "</div>\n";
  $ret .= "</div>\n";

  $ret .= "
  <script>
  \$('#remove$id').click(function() {
    \$.ajax({
       url: 'http://api.openstreetmap.cz/table/remove/$id',
    }).done(function() {
      \$('#remove$id').html('marked for deletion')
    });  
  });
  </script>
  ";

  return $ret;
}

################################################################################
sub t()
################################################################################
{
  my ($s, $lang) = @_;

  if ($s eq "Click to show items containing") {return "Zobraz položky obsahující";}
  if ($s eq "note") {return "Poznámka";}
  if ($s eq "nothing") {return "Vlož text ...";}
  if ($s eq "edited") {return "Editováno ...";}
  if ($s eq "remove_picture") {return "Smazat obrázek. Smazána budou pouze metadata, fotka bude skryta.";}
  if ($s eq "attribute") {return "Atribut";}
  if ($s eq "value") {return "Hodnota";}
  if ($s eq "isedited") {return "Bylo editováno?";}
  if ($s eq "Click to edit...") {return "Klikněte a editujte...";}
  if ($s eq "marked for delete") {return "Označeno pro smazání";}
  if ($s eq "times") {return "krát";}

#  return  utf8::decode($s);
  return $s;
}

################################################################################
sub show_table_row()
################################################################################
{
  my ($p1, $p2, $id, $col) = @_;

  my $out = "<!-- table row -->\n";
  $out .=
  "<div class='Row'>
    <div class='Cell'>
      <span>". $p1 ."</span>
    </div>
    <div class='Cell'>
       <span>" . $p2 . "</span>
    </div>
    <div class='Cell'>
      <div id='edited" . $col . $id . "'>checking ...</div>
    </div>
  </div>\n";
  $out .= "<!-- end table row -->\n";

  return $out;
}

################################################################################
sub show_table_header()
################################################################################
{
  my ($c1, $c2, $c3) = @_;

  my $out = "<!-- table header -->\n";
  $out .=
  "<div class='Row'>
    <div class='Cell'>
      <span>". $c1 ."</span>
    </div>
    <div class='Cell'>
       <span>" . $c2 . "</span>
    </div>
    <div class='Cell'>
       <span>" . $c3 . "</span>
    </div>
  </div>\n";
  $out .= "<!-- end table row -->\n";

  return $out;
}

################################################################################
sub edit_stuff
################################################################################
{
  my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @_;

  my $out;

  $out .= "<div class='Table'>";
  $out .= &show_table_header(&t("attribute"),&t("value"),&t("isedited"));
  $out .= &show_table_row("latitude", $lat, $id, "lat");
  $out .= &show_table_row("longtitude", $lon, $id, "lon");

  my $p1 = "<a title='" . &t("Click to show items containing") . " ref' href='/table/ref/" . $ref . "'>" . &t("ref") . "</a>:";
  my $p2 = "<div class='edit' id='ref_$id'>" . $ref . "</div>";
  $out .= &show_table_row($p1, $p2, $id, "ref");

  $out .= &show_table_row(
   "<a title='" . &t("Click to show items containing") . " name' href='/table/name/$attribution'>" . &t("by") . "</a>:",
   "<div class='edit' id='attribution_$id'>$attribution</div>",
   $id, "attribution"
  );
  $out .= &show_table_row(
   "<a title='" . &t("Click to show items containing") . " note' href='/table/note/$note'>" . &t("note") . "</a>:",
   "<div class='edit' id='note_$id'>$note</div>",
   $id, "note"
  );

  $out .= "</div>";

  return $out;
}

################################################################################
sub gp_line()
################################################################################
{
  my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @_;

  my $out = "<!-- GP LINE -->";

  if ($ref eq "") {
    $ref = "none";
  }

  if ($note eq "") {
    $note = &t("nothing");
  }

  $out .= "<hr>\n";
  $out .= "<div class='gp_line'>\n";

  $out .= "<div class='master_table'>";
  $out .= "<div class='Row'>";

  #id stuff
  $out .= "<div class='Cell'>\n";
  $out .= &id_stuff($id);
  $out .= "</div>\n";

  #edit stuff
  $out .= "<div class='Cell cell_middle'>\n";

  $out .= &edit_stuff($id, $lat, $lon, $url, $name, $attribution, $ref, $note);
  $out .= "</div>";

  @attrs= ("lat", "lon", "ref", "attribution", "note");

  $out .= "<script>";
  foreach $col (@attrs) {
    $out .= "
  \$.ajax({
    url: 'http://api.openstreetmap.cz/table/isedited/". $col ."/" . $id . "',
    timeout:3000
  })
  .done(function(data) {
    \$('#edited" . $col . $id . "').text(data);
  })
  .fail(function() {
    \$('#edited" . $col . $id . "').text('error');
  })
  .always(function(data) {
  });";
  }

    $out .= "
  var text = \"" . &delete_button() . "\";
  \$.ajax({
    url: 'http://api.openstreetmap.cz/table/isdeleted/" . $id . "',
    timeout:3000
  })
  .done(function(data) {
    if (data.length > 1) {
      \$('#remove" . $id . "').text(data);
    } else {
      \$('#remove" . $id . "').html(text);
    }
  })
  .fail(function() {
    \$('#remove" . $id . "').html(text + '??');
  })
  .always(function(data) {
  });";

  $out .= "  </script>";

  $out .= "<div class='Cell cell_middle'>";
  $out .= &maplinks($lat, $lon);
  $out .= "</div>\n";

  $out .= "<div class='Cell cell_middle'>";
  $out .= &static_map($lat, $lon);
  $out .= "</div>\n";


  $out .= "<div class='Cell'>";
  $full_uri = "http://api.openstreetmap.cz/".$url;
  $out .= "<a href='$full_uri'><img src='$full_uri' height='150px'><br>$name</a>";
  $out .= "</div>\n";

  $out .= "</div> <!-- row -->\n";
  $out .= "</div> <!-- table -->\n";

  $out .= "<textarea id='ta" . $id . "'>";
  $out .= &get_tags($id);
  $out .= "</textarea>\n";
  $out .= "<script>\n";
  $out .= "\$('#ta" . $id . "').tagEditor({

   autocomplete: { delay: 0, position: { collision: 'flip' }, source: ['infotabule', 'mapa', 'cyklo', 'ref', 'panorama', 'lyzarska', 'konska', 'rozcestnik', 'naucna', 'znaceni', 'zelena', 'cervena', 'zluta', 'modra', 'bila'] },
   placeholder: 'Vložte tagy ...',

   onChange: function(field, editor, tags) {
   },

   beforeTagSave: function(field, editor, tags, tag, val) {
     \$.ajax({
      url: 'http://api.openstreetmap.cz/table/tags/add/" . $id . "/' + val,
      timeout:3000
    })
    .done(function(data) {
      return true;
    })
    .fail(function() {
      return false;
    })
    .always(function(data) {
    });
   },

   beforeTagDelete: function(field, editor, tags, val) {
     \$.ajax({
      url: 'http://api.openstreetmap.cz/table/tags/delete/" . $id . "/' + val,
      timeout:3000
    })
    .done(function(data) {
      return true;
    })
    .fail(function() {
      return false;
    })
  }

  });\n";
  $out .= "</script>\n";

  $out .= "</div> <!-- gp_line -->\n";
#  syslog('info', $out);

  return $out;
}

################################################################################
sub get_gp_count
################################################################################
{
  my $query = "select count() from guidepost";
  my $sth = $dbh->prepare($query);
  my $rv = $sth->execute() or die $DBI::errstr;
  my @row = $sth->fetchrow_array();
  return $row[0];
}

################################################################################
sub page_header()
################################################################################
{
  my ($scripts, $links) = @_;
  my $out = '
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="cache-control" content="no-cache">
  <meta http-equiv="pragma" content="no-cache">
  <link rel="stylesheet" type="text/css" href="http://api.openstreetmap.cz/editor.css">
  <title>openstreetmap.cz guidepost editor</title>
';

  foreach $i (@$links) {
    $out .= "  <link rel='stylesheet' type='text/css' href='";
    $out .= $i;
    $out .= "'>\n";
  }

  foreach $i (@$scripts) {
    $out .= "  <script type='text/javascript' src='";
    $out .= $i;
    $out .= "'></script>\n";
  }

  $out .= '</head>
<body>
';

  return $out;
}

################################################################################
sub page_footer()
################################################################################
{
return '
</body>
</html>
';
}

################################################################################
sub set_by_id()
################################################################################
{
  my ($id, $val) = @_;
  my @data = split("_", $id);
  $db_id = $data[1];
  $db_col = $data[0];
  $query = "insert into changes (gp_id, col, value, action) values ($db_id, '$db_col', '$val', 'edit')";
#  syslog('info', $query);
  syslog('info', $r->connection->remote_ip . " wants to change id:$db_id, '$db_col' to '$val'");
  my $sth = $dbh->prepare($query);
  my $rv = $sth->execute() or die $DBI::errstr;
}

################################################################################
sub read_post()
################################################################################
{
  my $r = shift;
  my $bb = APR::Brigade->new($r->pool, $r->connection->bucket_alloc);
  my $data = '';
  my $seen_eos = 0;
  do {
    $r->input_filters->get_brigade($bb, Apache2::Const::MODE_READBYTES, APR::Const::BLOCK_READ, IOBUFSIZE);
    for (my $b = $bb->first; $b; $b = $bb->next($b)) {
      if ($b->is_eos) {
          $seen_eos++;
        last;
      }
      if ($b->read(my $buf)) {
        $data .= $buf;
      }
      $b->remove; # optimization to reuse memory
    }
  } while (!$seen_eos);
  $bb->destroy;
  return $data;
}


################################################################################
sub review_entry
################################################################################
{
  my ($req_id, $id, $gp_id, $col, $value, $img, $action) = @_;

  my $out = "";

  $out .= "<div id='reviewdiv$req_id'>";
  $out .= "<table>";
  $out .= "<tr>";
  $out .= "\n";

  if ($action eq "remove") {
    $out .= "<td><h2>DELETE</h2></td>";
  } elsif ($action eq "addtag") {
    $out .= "<td> <h2>add tags</h2></td>";
    $out .= "<td>Key: $col</td>";
    $out .= "<td>Value: $value</td>";
  } elsif ($action eq "deltag") {
    $out .= "<td> <h2>delete tags</h2></td>";
    $out .= "<td>Key: $col</td>";
    $out .= "<td>Value: $value</td>";
  } elsif ($action eq "edit") {

    $out .= "<td> <h2>change value</h2></td>";

    $original = &get_gp_column_value($gp_id, $col);

    $out .= "<td>column: $col</td>";
    $out .= "<td>original value: $original</td>";
    $out .= "<td>value: $value</td>";
  }

  $out .= "<td>change id:$id</td>";
  $out .= "<td>guidepost id:<a href='http://api.openstreetmap.cz/table/id/$gp_id'>$gp_id</a></td>";

  $out .= "\n";

  $out .= "</tr>";
  $out .= "</table>";
  $out .= "\n";

  $out .= "<table>";
  $out .= "<tr>";
  $out .= "<td>";
  $out .= "<img align='bottom' id='wheelzoom$req_id' src='http://api.openstreetmap.cz/img/guidepost/$img' width='320' height='200' alt='mapic'>";
  $out .= "</td>";
  $out .= "<td>";
  $out .= "<button style='height:200px;width:200px' onclick='javascript:reject(".$id."," . $req_id . ")' > reject </button>";
  $out .= "</td>";
  $out .= "<td>";
  $out .= "<button style='height:200px;width:200px' onclick='javascript:approve(".$id."," . $req_id . ")'> approve </button>";
  $out .= "</td>";
  $out .= "</table>";
  $out .= "\n";

  $out .= "</div>";
  $out .= "<hr>\n";

  return $out;
}

################################################################################
sub get_gp_column_value
################################################################################
{
  ($id, $column) = @_;
  $query = "select $column from guidepost where id=$id";

  if ($column eq "") {
    syslog("info", "get_gp_column_value $query");
  }

  @res = $dbh->selectrow_array($query) or return "db error error";

  if (!$res) {
    syslog("info", "get_gp_column_value dberror " . $DBI::errstr . " $query");
    return "error";
  }

  return $res[0];
}

################################################################################
sub review_form
################################################################################
{

  my $query = "select guidepost.name, changes.id, changes.gp_id, changes.col, changes.value, changes.action from changes, guidepost where changes.gp_id=guidepost.id limit 20";
  $res = $dbh->selectall_arrayref($query);
  print $DBI::errstr;
#http://code.jquery.com/jquery-1.11.3.min.js
#http://code.jquery.com/jquery-2.1.4.min.js
  my @a = ("http://code.jquery.com/jquery-1.11.3.min.js", "http://api.openstreetmap.cz/wheelzoom.js");
  print &page_header(\@a);

  print "<script>";
  print "
function approve(id,divid)
{
  \$.ajax( 'http://api.openstreetmap.cz/table/approve/' + id, function(data) {
    alert( 'Load was performed.' + data );
  })
  .done(function() {
  \$('#reviewdiv'+divid).css('background-color', 'lightgreen');
  })
  .fail(function() {
    alert( 'error' );
  })
  .always(function() {
  });
}

function reject(id,divid)
{
  \$.ajax( 'http://api.openstreetmap.cz/table/reject/' + id, function(data) {
    alert( 'Load was performed.'+data );
  })
  .done(function() {
  \$('#reviewdiv'+divid).css('background-color', 'red');
  })
  .fail(function() {
    alert( 'error' );
  })
  .always(function() {
  });
}

";

  print "</script>";

  print "\n<h1>Review</h1>\n";

  my $req_id = 0;
  foreach my $row (@$res) {
    my ($img, $id, $gp_id, $col, $value, $action) = @$row;
    print &review_entry($req_id++, $id, $gp_id, $col, $value, $img, $action);
  }

  print "<script>";
#  print "wheelzoom(document.querySelector('img.wheelzoom'));";
  print "wheelzoom(document.querySelectorAll('img'));";
  print "</script>\n";

  &page_footer();
}

################################################################################
sub is_edited
################################################################################
{
  $out = "";

  my ($what, $id) = @_;
  my $query = "select count() from changes where gp_id=$id and col='$what'";
  @res = $dbh->selectrow_array($query);

  if (!@res) {
    syslog("info", "is_edited dberror " . $DBI::errstr . " q: $query");
    $error_result = 500;
    return;
  }

  if ($res[0] > 0) {
    $out = " edited " . $ret[0] . "x";
  } else {
    $out = "";
  }
  $r->print($out);
}

################################################################################
sub is_deleted
################################################################################
{
  my $out - "";

  my ($id) = @_;
  my $query = "select count() from changes where gp_id=$id and action='remove'";
  my @ret = $dbh->selectrow_array($query);
#  print $DBI::errstr;
  if ($ret[0] > 0) {
    $out = &t("marked for delete") . " " . $ret[0] . " " . &t("times");
  } else {
    $out = "";
  }
  $r->print($out);
}

################################################################################
sub reject_edit
################################################################################
{
  my ($id) = @_;
  my $query = "delete from changes where id=$id";

  syslog('info', "removing change id: " . $id);

  $rv  = $dbh->do($query) or return $dbh->errstr;
  return "OK $id removed";
}

################################################################################
sub approve_edit
################################################################################
{
  my ($id) = @_;

  if (!&check_privileged_access()) {return;}

  syslog('info', "accepting change id: " . $id);

  my $query = "select * from changes where id='$id'";
  @res = $dbh->selectrow_array($query) or return $DBI::errstr;
  my ($xid, $gp_id, $col, $value, $action) = @res;

  if ($action eq "remove") {
    syslog('info', "deleting");
    &delete_id($gp_id);
  } elsif ($action eq "addtag") {
    my $query = "insert into tags values (null, $gp_id, '$col', '$value')";
    syslog('info', "adding tags " . $query);
    $rv  = $dbh->do($query) or return $dbh->errstr;
  } elsif ($action eq "edit") {
    my $query = "update guidepost set $col='$value' where id=$gp_id";
    syslog('info', "updating " . $query);
    $rv  = $dbh->do($query) or return $dbh->errstr;
  } elsif ($action eq "deltag") {
    my $query = "delete from tags where gp_id=$gp_id and k='$col' and v='$value'";
    syslog('info', "deleting tags " . $query);
    $rv  = $dbh->do($query) or return $dbh->errstr;
  }

  my $query = "delete from changes where id=$id";
  syslog('info', "removing change request " . $query);
  $rv  = $dbh->do($query) or return $dbh->errstr;
  return "OK $id changed";
}

################################################################################
sub delete_id
################################################################################
{
  my ($id) = @_;

  if (!&check_privileged_access()) {return;}

  syslog('info', "deleting id: " . $id);

  my $query = "select * from guidepost where id=$id";
#  $res = $dbh->selectall_hashref($query, { Slice => {} });
  $res = $dbh->selectall_hashref($query, 'id');

  my $original_file = "/home/walley/www/mapy/img/guidepost/" . $res->{$id}->{name};
  my $new_file = "/home/walley/www/mapy/img/guidepost/deleted/" . $res->{$id}->{name};

#move picture to backup directory
  syslog('info', "Moving $original_file to $new_file");
  if (!move($original_file, $new_file)) {
    syslog('info', "Move failed($original_file,$new_file): $!");
  }

#delete from db
  $query = "delete from guidepost where id='$id'";
  $dbh->do($query);
}

################################################################################
sub remove
################################################################################
{
  my ($id) = @_;
  syslog('info', $r->connection->remote_ip . " wants to remove $id");
  $query = "insert into changes (gp_id, action) values ($id, 'remove')";
  my $sth = $dbh->prepare($query);
  my $rv = $sth->execute() or die $DBI::errstr;
  print $query;
}

################################################################################
sub get_nearby()
################################################################################
{
  my ($lat, $lon, $m) = @_;
  syslog('info', "get_nearby(" . "$lat $lon $m)");
  ($minlat, $minlon) = get_latlon_offset_bbox($lat, $lon, -1 * $m, -1 * $m);
  ($maxlat, $maxlon) = get_latlon_offset_bbox($lat, $lon, $m, $m);
#  syslog('info', "get_nearby " . "$minlat $minlon $maxlat $maxlon");
  $BBOX = 1;
  $OUTPUT_FORMAT = "geojson";
  &output_all();
}

################################################################################
sub get_latlon_offset_bbox()
################################################################################
{
  my ($lat, $lon, $mx, $my) = @_;

 $R = 6378137;
 $dn = $mx;
 $de = $my;
 $dLat = $dn / $R;
 $dLon = $de / ($R * cos(3.14159269 * $lat / 180));
 $o_lat = $lat + $dLat * 180 / 3.14159269;
 $o_lon = $lon + $dLon * 180 / 3.14159269;

 return ($o_lat,  $o_lon);
}

################################################################################
sub get_tags()
################################################################################
{
  my ($id) = @_;
  my $out = "";
  my @out_array;
  my $query = "select * from tags where gp_id=$id";

  my $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    syslog("info", "get_tags dberror " . $DBI::errstr . "q: $query");
    $out = "DB error";
    return $out;
  }

  syslog("info", "get_tags($id):" . $query);

  my $i = 0;
  foreach my $row (@$res) {
    $out_array[$i++] .= @$row[2] . ":" . @$row[3];
#    syslog("info", "get_tags array" . $out_array[$i-1] );
  }

  $out .= join(";", @out_array);
  return $out;
}

################################################################################
sub add_tags()
################################################################################
{
  my ($id, $tag) = @_;
  my ($k, $v) = split(":", $tag);

  if ($k eq "" and $v eq "") {
    $error_result = 400;
    return;
  }

  $query = "insert into changes (gp_id, col, value, action) values ($id, '$k', '$v', 'addtag')";

  syslog("info", "add_tags($tag):" . $query);
  syslog('info', $r->connection->remote_ip . " wants to add tag ($k:$v) for id:$id");

  my $sth = $dbh->prepare($query);
  my $res = $sth->execute();

  if (!$res) {
    syslog("info", "add_tags($tag): dbi error " . $DBI::errstr);
    $error_result = 500;
  }

}

################################################################################
sub delete_tags()
################################################################################
{
  my ($id, $tag) = @_;
  my ($k, $v) = split(":", $tag);

  $query = "insert into changes (gp_id, col, value, action) values ($id, '$k', '$v', 'deltag')";
  syslog("info", "delete_tags($tag):" . $query);
  syslog('info', $r->connection->remote_ip . " wants to delete tag ($k:$v) for id:$id");

  my $sth = $dbh->prepare($query);
  my $res = $sth->execute();

  if (!$res) {
    syslog("info", "add_tags($tag): dbi error " . $DBI::errstr);
    $error_result = 500;
  }


}

1;
