#line 1
package Text::Xslate;
# The Xslate engine class
use 5.008_001;
use strict;
use warnings;

our $VERSION = '1.6002';

use Carp              ();
use File::Spec        ();
use Exporter          ();
use Data::MessagePack ();
use Scalar::Util      ();

use Text::Xslate::Util ();
BEGIN {
    # all the exportable functions are defined in ::Util
    our @EXPORT_OK = qw(
        mark_raw
        unmark_raw
        escaped_string
        html_escape
        uri_escape
        html_builder
    );
    Text::Xslate::Util->import(@EXPORT_OK);
}

our @ISA = qw(Text::Xslate::Engine);

my $BYTECODE_VERSION = '1.6';

# $bytecode_version + $fullpath + $compiler_and_parser_options
my $XSLATE_MAGIC   = qq{xslate;$BYTECODE_VERSION;%s;%s;};

# load backend (XS or PP)
my $use_xs = 0;
if(!exists $INC{'Text/Xslate/PP.pm'}) {
    my $pp = ($Text::Xslate::Util::DEBUG =~ /\b pp \b/xms or $ENV{PERL_ONLY});
    if(!$pp) {
        eval {
            require XSLoader;
            XSLoader::load(__PACKAGE__, $VERSION);
            $use_xs = 1;
        };
        die $@ if $@ && $Text::Xslate::Util::DEBUG =~ /\b xs \b/xms; # force XS
    }
    if(!__PACKAGE__->can('render')) {
        require 'Text/Xslate/PP.pm';
    }
}
sub USE_XS() { $use_xs }

# workaround warnings about numeric when it is a developpers' version
# it must be here because the bootstrap routine requires the under bar.
$VERSION =~ s/_//;

# for error messages (see T::X::Util)
sub input_layer { ref($_[0]) ? $_[0]->{input_layer} : ':utf8' }

package Text::Xslate::Engine; # XS/PP common base class

use Text::Xslate::Util qw(
    make_error
    dump
);

# constants
BEGIN {
    our @ISA = qw(Exporter);

    my $dump_load = scalar($Text::Xslate::Util::DEBUG =~ /\b dump=load \b/xms);
    *_DUMP_LOAD = sub(){ $dump_load };

    my $save_src = scalar($Text::Xslate::Util::DEBUG =~ /\b save_src \b/xms);
    *_SAVE_SRC  = sub() { $save_src };

    *_ST_MTIME = sub() { 9 }; # see perldoc -f stat

    my $cache_dir = '.xslate_cache';
    foreach my $d($ENV{HOME}, File::Spec->tmpdir) {
        if(defined($d) and -d $d and -w _) {
            $cache_dir = File::Spec->catfile($d, '.xslate_cache');
            last;
        }
    }
    *_DEFAULT_CACHE_DIR = sub() { $cache_dir };
}

# the real defaults are dfined in the parser
my %parser_option = (
    line_start => undef,
    tag_start  => undef,
    tag_end    => undef,
);

# the real defaults are defined in the compiler
my %compiler_option = (
    syntax     => undef,
    type       => undef,
    header     => undef, # template augment
    footer     => undef, # template agument
    macro      => undef, # template augment
);

my %builtin = (
    html_escape  => \&Text::Xslate::Util::html_escape,
    mark_raw     => \&Text::Xslate::Util::mark_raw,
    unmark_raw   => \&Text::Xslate::Util::unmark_raw,
    uri_escape   => \&Text::Xslate::Util::uri_escape,

    is_array_ref => \&Text::Xslate::Util::is_array_ref,
    is_hash_ref  => \&Text::Xslate::Util::is_hash_ref,

    dump         => \&Text::Xslate::Util::dump,

    # aliases
    raw          => 'mark_raw',
    html         => 'html_escape',
    uri          => 'uri_escape',
);

sub default_functions { +{} } # overridable

sub parser_option { # overridable
    return \%parser_option;
}

sub compiler_option { # overridable
    return \%compiler_option;
}

sub replace_option_value_for_magic_token { # overridable
    #my($self, $name, $value) = @_;
    #$value;
    return $_[2];
}

sub options { # overridable
    my($self) = @_;
    return {
        # name       => default
        suffix       => '.tx',
        path         => ['.'],
        input_layer  => $self->input_layer,
        cache        => 1, # 0: not cached, 1: checks mtime, 2: always cached
        cache_dir    => _DEFAULT_CACHE_DIR,
        module       => undef,
        function     => undef,
        html_builder_module => undef,
        compiler     => 'Text::Xslate::Compiler',

        verbose      => 1,
        warn_handler => undef,
        die_handler  => undef,

        %{ $self->parser_option },
        %{ $self->compiler_option },
    };
}

sub new {
    my $class = shift;
    my %args  = (@_ == 1 ? %{$_[0]} : @_);

    my $options = $class->options;
    my $used    = 0;
    my $nargs   = scalar keys %args;
    foreach my $key(keys %{$options}) {
        if(exists $args{$key}) {
            $used++;
        }
        elsif(defined($options->{$key})) {
            $args{$key} = $options->{$key};
        }
    }

    if($used != $nargs) {
        my @unknowns = sort grep { !exists $options->{$_} } keys %args;
        warnings::warnif(misc
            => "$class: Unknown option(s): " . join ' ', @unknowns);
    }

    $args{path} = [
        map { ref($_) ? $_ : File::Spec->rel2abs($_) }
            ref($args{path}) eq 'ARRAY' ? @{$args{path}} : $args{path}
    ];

    my $arg_function= $args{function};

    my %funcs;
    $args{function} = \%funcs;

    $args{template} = {}; # template structures

    my $self = bless \%args, $class;

    # definition of functions and methods

    # builtin functions
    %funcs = %builtin;
    $self->_register_builtin_methods(\%funcs);

    # per-class functions
    $self->_merge_hash(\%funcs, $class->default_functions());

    # user-defined functions
    if(defined $args{module}) {
        $self->_merge_hash(\%funcs,
            Text::Xslate::Util::import_from(@{$args{module}}));
    }

    # user-defined html builder functions
    if(defined $args{html_builder_module}) {
        my $raw = Text::Xslate::Util::import_from(@{$args{html_builder_module}});
        my $html_builders = +{
            map {
                ($_ => &Text::Xslate::Util::html_builder($raw->{$_}))
            } keys %$raw
        };
        $self->_merge_hash(\%funcs, $html_builders);
    }

    $self->_merge_hash(\%funcs, $arg_function);

    $self->_resolve_function_aliases(\%funcs);

    return $self;
}

sub _merge_hash {
    my($self, $base, $add) = @_;
    foreach my $name(keys %{$add}) {
        $base->{$name} = $add->{$name};
    }
    return;
}

sub _resolve_function_aliases {
    my($self, $funcs) = @_;

    foreach my $f(values %{$funcs}) {
        my %seen; # to avoid infinate loops
        while(!( ref($f) or Scalar::Util::looks_like_number($f) )) {
            my $v = $funcs->{$f} or $self->_error(
               "Cannot resolve a function alias '$f',"
               . " which refers nothing",
            );

            if( ref($v) or Scalar::Util::looks_like_number($v) ) {
                $f = $v;
                last;
            }
            else {
                $seen{$v}++ and $self->_error(
                    "Cannot resolve a function alias '$f',"
                    . " which makes circular references",
                );
            }
        }
    }

    return;
}

sub load_string { # called in render_string()
    my($self, $string) = @_;
    if(not defined $string) {
        $self->_error("LoadError: Template string is not given");
    }
    $self->note('  _load_string: %s', join '\n', split /\n/, $string)
        if _DUMP_LOAD;
    $self->{source}{'<string>'} = $string if _SAVE_SRC;
    $self->{string_buffer} = $string;
    my $asm = $self->compile($string);
    $self->_assemble($asm, '<string>', \$string, undef, undef);
    return $asm;
}

my $updir = File::Spec->updir;
sub find_file {
    my($self, $file) = @_;

    if($file =~ /\Q$updir\E/xmso) {
        $self->_error("LoadError: Forbidden component (updir: '$updir') found in file name '$file'");
    }

    my $fullpath;
    my $cachepath;
    my $orig_mtime;
    my $cache_mtime;
    foreach my $p(@{$self->{path}}) {
        $self->note("  find_file: %s in  %s ...\n", $file, $p) if _DUMP_LOAD;

        my $cache_prefix;
        if(ref $p eq 'HASH') { # virtual path
            defined(my $content = $p->{$file}) or next;
            $fullpath = \$content;

            # NOTE:
            # Because contents of virtual paths include their digest,
            # time-dependent cache verifier makes no sense.
            $orig_mtime   = 0;
            $cache_mtime  = 0;
            $cache_prefix = 'HASH';
        }
        else {
            $fullpath = File::Spec->catfile($p, $file);
            defined($orig_mtime = (stat($fullpath))[_ST_MTIME])
                or next;
            $cache_prefix = Text::Xslate::uri_escape($p);
            if (length $cache_prefix > 127) {
                # some filesystems refuse a path part with length > 127
                $cache_prefix = $self->_digest($cache_prefix);
            }
        }

        # $file is found
        $cachepath = File::Spec->catfile(
            $self->{cache_dir},
            $cache_prefix,
            $file . 'c',
        );
        # stat() will be failed if the cache doesn't exist
        $cache_mtime = (stat($cachepath))[_ST_MTIME];
        last;
    }

    if(not defined $orig_mtime) {
        $self->_error("LoadError: Cannot find '$file' (path: @{$self->{path}})");
    }

    $self->note("  find_file: %s (mtime=%d)\n",
        $fullpath, $cache_mtime || 0) if _DUMP_LOAD;

    return {
        name        => ref($fullpath) ? $file : $fullpath,
        fullpath    => $fullpath,
        cachepath   => $cachepath,

        orig_mtime  => $orig_mtime,
        cache_mtime => $cache_mtime,
    };
}


sub load_file {
    my($self, $file, $mtime, $omit_augment) = @_;

    local $self->{omit_augment} = $omit_augment;

    $self->note("%s->load_file(%s)\n", $self, $file) if _DUMP_LOAD;

    if($file eq '<string>') { # simply reload it
        return $self->load_string($self->{string_buffer});
    }

    my $fi = $self->find_file($file);

    my $asm = $self->_load_compiled($fi, $mtime) || $self->_load_source($fi, $mtime);

    # $cache_mtime is undef : uses caches without any checks
    # $cache_mtime > 0      : uses caches with mtime checks
    # $cache_mtime == 0     : doesn't use caches
    my $cache_mtime;
    if($self->{cache} < 2) {
        $cache_mtime = $fi->{cache_mtime} || 0;
    }

    $self->_assemble($asm, $file, $fi->{fullpath}, $fi->{cachepath}, $cache_mtime);
    return $asm;
}

sub slurp_template {
    my($self, $input_layer, $fullpath) = @_;

    open my($source), '<' . $input_layer, $fullpath
        or $self->_error("LoadError: Cannot open $fullpath for reading: $!");
    local $/;
    return scalar <$source>;
}

sub _load_source {
    my($self, $fi) = @_;
    my $fullpath  = $fi->{fullpath};
    my $cachepath = $fi->{cachepath};

    $self->note("  _load_source: try %s ...\n", $fullpath) if _DUMP_LOAD;

    # This routine is called when the cache is no longer valid (or not created yet)
    # so it should be ensured that the cache, if exists, does not exist
    if(-e $cachepath) {
        unlink $cachepath
            or Carp::carp("Xslate: cannot unlink $cachepath (ignored): $!");
    }

    my $source = $self->slurp_template($self->input_layer, $fullpath);
    $self->{source}{$fi->{name}} = $source if _SAVE_SRC;

    my $asm = $self->compile($source,
        file => $fullpath,
        name => $fi->{name},
    );

    if($self->{cache} >= 1) {
        my($volume, $dir) = File::Spec->splitpath($fi->{cachepath});
        my $cachedir      = File::Spec->catpath($volume, $dir, '');
        if(not -e $cachedir) {
            require File::Path;
            eval { File::Path::mkpath($cachedir) }
                or Carp::croak("Xslate: Cannot prepare cache directory $cachepath (ignored): $@");
        }

        my $tmpfile = sprintf('%s.%d.d', $cachepath, $$, $self);

        if (open my($out), ">:raw", $tmpfile) {
            my $mtime = $self->_save_compiled($out, $asm, $fullpath, utf8::is_utf8($source));

            if(!close $out) {
                 Carp::carp("Xslate: Cannot close $cachepath (ignored): $!");
                 unlink $tmpfile;
            }
            elsif (rename($tmpfile => $cachepath)) {
                # set the newest mtime of all the related files to cache mtime
                if (not ref $fullpath) {
                    my $main_mtime = (stat $fullpath)[_ST_MTIME];
                    if (defined($main_mtime) && $main_mtime > $mtime) {
                        $mtime = $main_mtime;
                    }
                    utime $mtime, $mtime, $cachepath;
                    $fi->{cache_mtime} = $mtime;
                }
                else {
                    $fi->{cache_mtime} = (stat $cachepath)[_ST_MTIME];
                }
            }
            else {
                Carp::carp("Xslate: Cannot rename cache file $cachepath (ignored): $!");
                unlink $tmpfile;
            }
        }
        else {
            Carp::carp("Xslate: Cannot open $cachepath for writing (ignored): $!");
        }
    }
    if(_DUMP_LOAD) {
        $self->note("  _load_source: cache(mtime=%s)\n",
            defined $fi->{cache_mtime} ? $fi->{cache_mtime} : 'undef');
    }

    return $asm;
}

# load compiled templates if they are fresh enough
sub _load_compiled {
    my($self, $fi, $threshold) = @_;

    if($self->{cache} >= 2) {
        # threshold is the most latest modified time of all the related caches,
        # so if the cache level >= 2, they seems always fresh.
        $threshold = 9**9**9; # force to purge the cache
    }
    else {
        $threshold ||= $fi->{cache_mtime};
    }
    # see also tx_load_template() in xs/Text-Xslate.xs
    if(!( defined($fi->{cache_mtime}) and $self->{cache} >= 1
            and $threshold >= $fi->{orig_mtime} )) {
        $self->note( "  _load_compiled: no fresh cache: %s, %s",
            $threshold || 0, Text::Xslate::Util::p($fi) ) if _DUMP_LOAD;
        $fi->{cache_mtime} = undef;
        return undef;
    }

    my $cachepath = $fi->{cachepath};
    open my($in), '<:raw', $cachepath
        or $self->_error("LoadError: Cannot open $cachepath for reading: $!");

    my $magic = $self->_magic_token($fi->{fullpath});
    my $data;
    read $in, $data, length($magic);
    if($data ne $magic) {
        return undef;
    }
    else {
        local $/;
        $data = <$in>;
        close $in;
    }
    my $unpacker = Data::MessagePack::Unpacker->new();
    my $offset  = $unpacker->execute($data);
    my $is_utf8 = $unpacker->data();
    $unpacker->reset();

    $unpacker->utf8($is_utf8);

    my @asm;
    if($is_utf8) { # TODO: move to XS?
        my $seed = "";
        utf8::upgrade($seed);
        push @asm, ['print_raw_s', $seed, __LINE__, __FILE__];
    }
    while($offset < length($data)) {
        $offset = $unpacker->execute($data, $offset);
        my $c = $unpacker->data();
        $unpacker->reset();

        # my($name, $arg, $line, $file, $symbol) = @{$c};
        if($c->[0] eq 'depend') {
            my $dep_mtime = (stat $c->[1])[_ST_MTIME];
            if(!defined $dep_mtime) {
                Carp::carp("Xslate: Failed to stat $c->[1] (ignored): $!");
                return undef; # purge the cache
            }
            if($dep_mtime > $threshold){
                $self->note("  _load_compiled: %s(%s) is newer than %s(%s)\n",
                    $c->[1],    scalar localtime($dep_mtime),
                    $cachepath, scalar localtime($threshold) )
                        if _DUMP_LOAD;
                return undef; # purge the cache
            }
        }
        push @asm, $c;
    }

    if(_DUMP_LOAD) {
        $self->note("  _load_compiled: cache(mtime=%s)\n",
            defined $fi->{cache_mtime} ? $fi->{cache_mtime} : 'undef');
    }

    return \@asm;
}

sub _save_compiled {
    my($self, $out, $asm, $fullpath, $is_utf8) = @_;
    my $mp = Data::MessagePack->new();
    local $\;
    print $out $self->_magic_token($fullpath);
    print $out $mp->pack($is_utf8 ? 1 : 0);

    my $newest_mtime = 0;
    foreach my $c(@{$asm}) {
        print $out $mp->pack($c);

        if ($c->[0] eq 'depend') {
            my $dep_mtime = (stat $c->[1])[_ST_MTIME];
            if ($newest_mtime < $dep_mtime) {
                $newest_mtime = $dep_mtime;
            }
        }
    }
    return $newest_mtime;
}

sub _magic_token {
    my($self, $fullpath) = @_;

    $self->{serial_opt} ||= Data::MessagePack->pack([
        ref($self->{compiler}) || $self->{compiler},
        $self->_filter_options_for_magic_token($self->_extract_options($self->parser_option)),
        $self->_filter_options_for_magic_token($self->_extract_options($self->compiler_option)),
        $self->input_layer,
        [sort keys %{ $self->{function} }],
    ]);

    if(ref $fullpath) { # ref to content string
        $fullpath = join ':', ref($fullpath),
            $self->_digest(${$fullpath});
    }
    return sprintf $XSLATE_MAGIC, $fullpath, $self->{serial_opt};
}

sub _digest {
    my($self, $content) = @_;
    require 'Digest/MD5.pm'; # we don't want to create its namespace
    my $md5 = Digest::MD5->new();
    utf8::encode($content);
    $md5->add($content);
    return $md5->hexdigest();
}

sub _extract_options {
    my($self, $opt_ref) = @_;
    my @options;
    foreach my $name(sort keys %{$opt_ref}) {
        if(exists $self->{$name}) {
            push @options, $name => $self->{$name};
        }
    }
    return @options;
}

sub _filter_options_for_magic_token {
    my($self, @options) = @_;
    my @filterd_options;
    while (@options) {
        my $name  = shift @options;
        my $value = $self->replace_option_value_for_magic_token($name, shift @options);
        push(@filterd_options, $name => $value);
    }
    @filterd_options;
}



sub _compiler {
    my($self) = @_;
    my $compiler = $self->{compiler};

    if(!ref $compiler){
        require Any::Moose;
        Any::Moose::load_class($compiler);

        my $input_layer = $self->input_layer;
        $compiler = $compiler->new(
            engine      => $self,
            input_layer => $input_layer,
            $self->_extract_options($self->compiler_option),
            parser_option => {
                input_layer => $input_layer,
                $self->_extract_options($self->parser_option),
            },
        );

        $compiler->define_function(keys %{ $self->{function} });

        $self->{compiler} = $compiler;
    }

    return $compiler;
}

sub compile {
    my $self = shift;
    return $self->_compiler->compile(@_,
        omit_augment => $self->{omit_augment});
}

sub _error {
    die make_error(@_);
}

sub note {
    my($self, @args) = @_;
    printf STDERR @args;
}

package Text::Xslate;
1;
__END__

#line 1183

#line 1306
