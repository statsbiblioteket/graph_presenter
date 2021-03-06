#!/bin/bash

#
# Takes a SVG as input, generates a PNG rendering, DeepZoom tiles and a JSON
# block containing node coordinates for search.
#

###############################################################################
# CONFIG
###############################################################################


if [[ -s "linkgraph.conf" ]]; then
    source "linkgraph.conf"     # Local overrides
fi
pushd ${BASH_SOURCE%/*} > /dev/null
SCRIPT_HOME="$(pwd)"

: ${SVG:="$1"}
BASE=$(basename -- "$SVG")
BASE=${BASE%.*}
DZI="${BASE}.dzi"
: ${DEST:="$2"}
: ${DEST:="$BASE"}
: ${PNG:="${DEST}/${BASE}.png"}
: ${TEMPLATE:="$(pwd)/presentation_template.html"}

# If true, only the metadata are processed
# Use vips for generating both PNG and tiles.
# Important: This fails for renders > 32Kx32K unless a suitable new version of vips is used.
# See https://github.com/libvips/libvips/issues/1354 for details
: ${VIPS_ONLY:="auto"} # auto means true if vips-version is 8.9+, else false

: ${RENDER_PNG:="auto"} # false, true, auto (only if needed for tiles)
: ${RENDER_TILES:="true"}
: ${RENDER_META:="true"}

# PNG & DeepZoom tile parameters
: ${RENDER_SIZE:="10000"}
: ${RENDER_WIDTH:="$RENDER_SIZE"}
: ${RENDER_HEIGHT:="$RENDER_SIZE"}
: ${FORMAT:="png"} # Gephi charts are circles, lines and text so PNG is probably best choice

# sed performance tuning
: ${SED_BATCH_SIZE:="500"} # 500 was selected from a few ad hoc experiments. Increasing beyond 1000 slows overall processing
: ${SED_THREADS:=$(nproc)} # Increasing this well (3x) beyond the number of physical cores has a positive effect (30-40%)

# Where to get OpenSeadragon
: ${OSD_VERSION:=2.2.1}
: ${OSD_ZIP:="openseadragon-bin-${OSD_VERSION}.zip"}
: ${OSD_URL:="http://github.com/openseadragon/openseadragon/releases/download/v${OSD_VERSION}/$OSD_ZIP"}

: ${DAT_LINKS:="${DEST}/links.dat"}
: ${DAT_POS:="${DEST}/position.dat"}
: ${DAT_ALL:="${DEST}/all.dat"}
: ${DAT_CL:="${DEST}/coordinates_links.dat"}
: ${DAT_CL_INDEX:="${DEST}/coordinates_links_index.dat"}
: ${DAT_CL_INDEX_TEXT:="${DEST}/coordinates_links_index_text.dat"}
: ${DAT_OUT:="${DEST}/links_out.dat"}
: ${DAT_IN:="${DEST}/links_in.dat"}
: ${DAT_IN_OUT:="${DEST}/links_in_out.dat"}
: ${DAT_TEXT:="${DEST}/text.dat"}

# We need to declase associative arrays at the root (why?)
declare -A DOMAIN_INDEX_MAP
popd > /dev/null

function usage() {
    cat <<EOF
Usage: ./generate_presentation mygraph.svg"

See variables in source code for extra options. Specify by setting environment 
variables before the script is calles, e.g.

RENDER_SIZE=5000 RENDER_PNG=false VIPS_ONLY=true DEST=wiki_5K ./generate_presentation.sh wikipedia_dk.svg 
EOF
    exit $1
}

check_parameters() {
    if [[ -z "$SVG" ]]; then
        >&2 echo "Error: No input file specified"
        usage 2
    fi 
    if [[ ! -s "$SVG" ]]; then
        >&2 echo "Error: Unable to read '$SVG'"
        usage 3
    fi
    mkdir -p "$DEST"

    local MISSING=false
    if [[ .$(which vips) == . ]]; then
        if [[ "true" == "$RENDER_TILES" ]]; then
            >&2 echo "Error: 'vips' not available, please install it"
            MISSING=true
        elif [[ "true" == "$VIPS_ONLY" && "true" == "$RENDER_PNG" ]]; then
            >&2 echo "Error: 'vips' not available, please install it"
            MISSING=true
        fi
    fi
    if [[ "true" == "$MISSING" ]]; then
        usage 2
    fi

    if [[ .$(which xmllint) == . ]]; then
        >&2 echo "Error: 'xmllint' not available, please install it"
        usage 3
    fi

    if [[ "auto" == "$VIPS_ONLY" ]]; then
        # vips 8.9 can handle large SVGs, both input and output
        # See https://github.com/libvips/libvips/issues/732
        # and https://github.com/libvips/libvips/issues/1354
        local V=$(vips -v | grep -o '[0-9]\+[.][0-9]\+[.][0-9]\+')
        local VE=(${V//./ })
        if [[ ${VE[0]} -gt 8 || ( ${VE[0]} -eq 8 && ${VE[1]} -ge 9) ]]; then
            echo "- VIPS_ONLY==auto and vips version $V >= 8.9.0. Setting VIPS_ONLY=true"
            VIPS_ONLY=true
        else
            echo "- VIPS_ONLY==auto and vips version $V < 8.9.0. Setting VIPS_ONLY=false"
            VIPS_ONLY=false
        fi
    fi

    if [[ "$RENDER_PNG" == "auto" ]]; then
        if [[ "$VIPS_ONLY" == "true" ]]; then
            echo "- VIPS_ONLY==true and RENDER_PNG==auto. Setting RENDER_PNG=false"
        else 
            echo "- VIPS_ONLY==false and RENDER_PNG==auto. Setting RENDER_PNG=true"
        fi
    fi
    
    if [[ "false" == "$VIPS_ONLY" && .$(which gm) == . ]]; then
        >&2 echo "Error: 'gm' (GraphicsMagic) not available, please install it"
        MISSING=true
    fi

    SVG_ABSOLUTE=$(echo "$(cd "$(dirname "$SVG")"; pwd)/$(basename "$SVG")")
    PNG_ABSOLUTE=$(echo "$(cd "$(dirname "$PNG")"; pwd)/$(basename "$PNG")")
}

################################################################################
# FUNCTIONS
################################################################################

fetch_dragon() {
    if [[ -s "$SCRIPT_HOME/osd/$OSD_ZIP" ]]; then
        return
    fi
    mkdir -p "$SCRIPT_HOME/osd/"
    echo "  - Fetching $OSD_ZIP from $OSD_URL"
    wget -q "$OSD_URL" -O  "$SCRIPT_HOME/osd/$OSD_ZIP"
    if [[ ! -s "$SCRIPT_HOME/osd/$OSD_ZIP" ]]; then
        >&2 echo "Error: Unable to fetch OpenSeadragon ZIP from $OSD_URL"
        >&2 echo "Please download is manually and store it in $SCRIPT_HOME/osd/"
        exit 3
    fi
}

# Expands variables and callbacks in the provided template
# http://stackoverflow.com/questions/14434549/how-to-expand-shell-variables-in-a-text-file
# Input: template-file
function ctemplate() {
    if [[ ! -s "$1" ]]; then
        >&2 echo "Error: Template '$1' could not be found"
        exit 8
    fi
    local TMP=$(mktemp /tmp/graph_presenter_XXXXXXXX)
    echo 'cat <<END_OF_TEXT' >  "$TMP"
    cat  "$1"                >> "$TMP"
    echo 'END_OF_TEXT'       >> "$TMP"
    . "$TMP"
    rm "$TMP"
}

# Returns largest DPI from wanted width & height 
get_dpi() {
    local W_DPI=$(( $RENDER_WIDTH * 72 / $(head -n 100 "$SVG" | tr '\n' ' ' | grep -o '<svg[^<]*width="[0-9.]*"' | grep -o 'width=.*' | sed 's/[^0-9]*\([0-9]*\).*/\1/') ))
    local H_DPI=$(( $RENDER_HEIGHT * 72 / $(head -n 100 "$SVG" | tr '\n' ' ' | grep -o '<svg[^<]*height="[0-9.]*"' | grep -o 'height=.*' | sed 's/[^0-9]*\([0-9]*\).*/\1/') ))
    if [[ "$W_DPI" -lt "$H_DPI" ]]; then
        echo "$H_DPI"
    else
        echo "$W_DPI"
    fi
}

create_png() {
    if [[ -s "$PNG" ]]; then
        echo "- Skipping generation of $PNG as it already exists"
        return
    fi
    if [[ "true" == "$VIPS_ONLY" ]]; then
        local DPI=$(get_dpi)
        echo "- Generating $PNG with minimum dimensions ${RENDER_WIDTH}x${RENDER_HEIGHT} pixels (dpi=${SPI}) using vips"
        vips copy "${SVG}[dpi=${DPI},unlimited]" "$PNG"
    else
        echo "- Generating $PNG with dimensions ${RENDER_WIDTH}x${RENDER_HEIGHT} pixels using GraphicsMagic"
        # ImageMagic does not handle large SVGs well, so we use GraphicsMagic
        gm convert -size ${RENDER_WIDTH}x${RENDER_HEIGHT} "$SVG" "$PNG"
    fi
}

create_deepzoom() {
    if [[ -d "${DEST}/${BASE}_files" ]]; then
        echo "- Skipping DeepZoom tile generation as '${DEST}/${BASE}_files' already exists"
        return
    fi

    local VIPS_DIRECT=false
    if [[ ! -s "$PNG" ]]; then
        if [[ "false" == "$VIPS_ONLY" ]]; then
            echo "- Illegal combination: No PNG and VIPS_ONLY=false. Force-enabling direct vips based SVG→tiles rendering"
        fi
        VIPS_DIRECT="true"
    else
        if [[ "true" == "$VIPS_ONLY" ]]; then
            echo "- PNG exists (${PNG}), but VIPS_ONLY=true: Tiles will be generated from SVG ($SVG)"
            VIPS_DIRECT="true"
        fi
        
    fi
    if [[ "true" == "$VIPS_DIRECT" ]]; then
        local DPI=$(get_dpi)
        echo "- Generating DeepZoom tiles in ${DEST}/${BASE}_files using vips from SVG with DPI=${DPI}"
        pushd "$DEST" > /dev/null
        vips dzsave "${SVG_ABSOLUTE}[dpi=${DPI},unlimited]" ${BASE} --suffix .$FORMAT
        popd > /dev/null
    else
        echo "- Generating DeepZoom tiles in ${DEST}/${BASE}_files using vips from PNG"
        pushd "$DEST" > /dev/null
        vips dzsave ${PNG_ABSOLUTE} ${BASE} --suffix .$FORMAT
        popd > /dev/null
    fi
}


#        <circle fill-opacity="1.0" fill="#ff5584" r="20.0" cx="-54.279125"
#                class="id_ekot.dk" cy="-78.99566" stroke="#000000"
#                stroke-opacity="1.0" stroke-width="1.0"/>

normalise_svg() {
    tr '\n' ' ' < "$SVG" | sed -e 's/> */>/g' -e 's/ *</</g' | xmllint --format - 
}

collapse() {
    local LAST="%%%"
    while IFS= read -r PAIR; do
        local TOKENS=($PAIR)
        local LEFT=${TOKENS[0]}
        local RIGHT=${TOKENS[1]}
        if [[ "$LAST" == "$LEFT" ]]; then
            echo -n ";$RIGHT"
        else
            if [[ "$LAST" != "%%%" ]]; then
                echo "\""
            fi
            echo -n "$LEFT \"$RIGHT"
        fi
        LAST="$LEFT"
    done
    echo "\""
}

# domain in_links out_links
extract_links() {
    if [[ ! -s "$DAT_IN_OUT" ]]; then
        # Yes we need sort both before and after collapse
        normalise_svg | grep 'class="id_.* id_' | sed 's/.* d="M [^ ]* C \([^ ]*\) \([^ ]*\) .*class="id_\([^ ]*\) id_\([^ ]*\)".*stroke="\([^"]*\)".*/\3 §\4§(\1~\2\5)/' | LC_ALL=c sort -u | collapse | LC_ALL=c sort > "$DAT_OUT"
        # TODO: Consider storing only the path-coordinates for one way
        normalise_svg | grep 'class="id_.* id_' | sed 's/.* d="M [^ ]* C \([^ ]*\) \([^ ]*\) .*class="id_\([^ ]*\) id_\([^ ]*\)".*stroke="\([^"]*\)".*/\4 §\3§(\1~\2\5)/' | LC_ALL=c sort -u | collapse | LC_ALL=c sort > "$DAT_IN"
#        grep 'class="id_.* id_' "$SVG" | sed 's/.*class="id_\([^ ]*\) id_\([^ ]*\)".*/\1 \2/' | LC_ALL=c sort -u | collapse | LC_ALL=c sort > "$DAT_OUT"
#        grep 'class="id_.* id_' "$SVG" | sed 's/.*class="id_\([^ ]*\) id_\([^ ]*\)".*/\2 \1/' | LC_ALL=c sort -u | collapse | LC_ALL=c sort > "$DAT_IN"
        LC_ALL=C join -j 1 -a 1 -a 2 -e '""' -o 0 1.2 2.2 "$DAT_IN" "$DAT_OUT" > "$DAT_IN_OUT"
    fi
    cat "$DAT_IN_OUT"
}

# fontsize & fontname
extract_text_properties() {
    if [[ ! -s "$DAT_TEXT" ]]; then
        normalise_svg | grep '<text.* class="id_.*' | sed 's/.*font-size="\([^"]*\)".*font-family="\([^"]*\)".*class="id_\([^" ]*\).*/\3 \1 "\2"/' | LC_ALL=c sort -u > "$DAT_TEXT"
    fi
    cat "$DAT_TEXT"
}

# domain in out total
extract_link_stats() {
    if [[ ! -s "$DAT_LINKS" ]]; then
        local T_IN=$(mktemp)
        local T_OUT=$(mktemp)
        grep -o 'class="[^ "]\+ id_[^"]*' "$SVG" | sed 's/class="[^ "]\+ id_\(.*\)/\1/' | LC_ALL=c sort | LC_ALL=c uniq -c | sed 's/\s*\([0-9]*\) \(.*\)/\2 \1/' | LC_ALL=C sort > $T_IN
        grep -o 'class="id_[^ "]* ' "$SVG" | sed 's/class="id_\(.*\) /\1/' | LC_ALL=c sort | LC_ALL=c uniq -c | sed 's/\s*\([0-9]*\) \(.*\)/\2 \1/' | LC_ALL=C sort > $T_OUT
        LC_ALL=C join -j 1 -a 1 -a 2 -e 0 -o 0 1.2 2.2 $T_IN $T_OUT | sed 's/\(.*\) \([0-9]\+\) \([0-9]\+\)$/echo "\1 \2 \3 $((\2+\3))"/e' > "$DAT_LINKS"
        rm $T_IN $T_OUT
    fi
    cat "$DAT_LINKS"
}

extract_textfont() {
    echo "var textfont=\"$(normalise_svg | grep '<text' | head -n 1 | sed 's/.*font-family="\([^"]*\)".*/\1/')\";"
}   

extract_viewbox() {
    grep -o 'viewBox="[^"]*' < "$SVG" | sed 's/.*"\([^ ]*\) *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) */var viewbox= {x1: \1, y1: \2, x2: \3, y2: \4};/'
}

# domain x y r
extract_nodes_circles_raw() {
    if [[ ! -s "$DAT_POS" ]]; then
        tr '\n' ' ' < "$SVG" | grep -o "<circle [^/]*/>" | sed 's/<circle.* r="\([^"]*\)".* cx="\([^"]*\)".* class="id_\([^"]*\)".* cy="\([^"]*\)".*\/>/\3 \2 \4 \1/' | LC_ALL=C sort -u > "$DAT_POS"
    fi
    cat "$DAT_POS"
}

# domain x y r in_links out_links
extract_coordinates_links() {
    if [[ ! -s "$DAT_CL" ]]; then
        LC_ALL=c join -j 1 -a 1 -a 2 -e '""' -o 0 1.2 1.3 1.4 2.2 2.3 <(extract_nodes_circles_raw) <(extract_links) > "$DAT_CL"
    fi              
    cat "$DAT_CL"
}

# sed chokes with hundred of thousands of rules.
# split_sed takes a file with rules and splits them into chunks
# as well as chaining multiple seds for higher performance
#
# Batch size as well as thread size is set with SED_BATCH_SIZE and SED_THREADS
#
# input: input_file rule_file output_file
split_sed() {
    local FIN="$1"
    local RULES="$2"
    local FOUT="$3"

    local SRC=$(mktemp)
    cp "$FIN" "$SRC"
    local T=$(mktemp)
    local RULE_TMP=$(mktemp)
    split -l $SED_BATCH_SIZE "$RULES" "${RULE_TMP}_"
    local SEDS=""
    local SED_COUNT=0
    local EXE_COUNT=0
    local TOTAL_RULES=$(wc -l < "$FIN")
    while IFS=  read -r RULE_FILE; do
        SEDS="$SEDS | sed -f \"$RULE_FILE\""
        SED_COUNT=$((SED_COUNT+1))
        if [[ "$SED_COUNT" -eq "$SED_THREADS" ]]; then
            EXE_COUNT=$((EXE_COUNT+1))
            # TODO: Don't provide this feedback on stderr
            >&2 echo "Activating $SED_THREADS seds @ $SED_BATCH_SIZE rules (out of $TOTAL_RULES total rules) number $EXE_COUNT at $(date +"%Y-%m-%d %H:%M")"
            bash -c "cat \"$SRC\"$SEDS > \"$T\" ; mv \"$T\" \"$SRC\""
            SEDS=""
            SED_COUNT=0
        fi
    done < <(ls ${RULE_TMP}_*)
    if [[ "$SED_COUNT" -ne "0" ]]; then
        bash -c "cat \"$SRC\"$SEDS > \"$T\" ; mv \"$T\" \"$SRC\""
    fi

    mv "$SRC" "$FOUT"
    
    rm ${RULE_TMP} ${RULE_TMP}_*
    if [[ -f "$T" ]]; then
        rm "$T"
    fi
}

# domain x y r in_links_indexes out_links_indexes
extract_coordinates_links_index() {
    if [[ ! -s "$DAT_CL_INDEX" ]]; then
        local T_SED=$(mktemp)
        local INDEX=0
        while IFS= read -r LINE; do
            local D=${LINE%% *}
            echo "s/§${D}§/${INDEX}/g" >> "$T_SED"
            INDEX=$((INDEX+1))
        done < <(extract_coordinates_links)
        split_sed "$DAT_CL" "$T_SED" "$DAT_CL_INDEX"
#        sed -f "$T_SED" <<< $(extract_coordinates_links) > "$DAT_CL_INDEX"
        rm "$T_SED"
    fi
    cat "$DAT_CL_INDEX"
}

# domain x y r in_links_indexes out_links_indexes fontsize
extract_coordinates_links_index_text() {
    if [[ ! -s "$DAT_CL_INDEX_TEXT" ]]; then
        LC_ALL=c join -j 1 -a 1 -a 2 -e '12' -o 0 1.2 1.3 1.4 1.5 1.6 2.2 <(extract_coordinates_links_index) <(extract_text_properties) > "$DAT_CL_INDEX_TEXT"
    fi
    cat "$DAT_CL_INDEX_TEXT"
}

# domain x y r in out all
extract_all_raw() {
    if [[ ! -s "$DAT_ALL" ]]; then
        LC_ALL=c join -j 1 -a 1 -a 2 -e 0 -o 0 2.2 2.3 2.4 1.2 1.3 1.4 <(extract_link_stats) <(extract_nodes_circles_raw) > "$DAT_ALL"
    fi              
    cat "$DAT_ALL"
}

extract_domains() {
    echo "var domains= ["
    extract_all_raw | sed 's/\([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\)/{d:"\1", x:\2, y:\3, r:\4, in:\5, out:\6, both:\7},/'
    echo "];"
}

extract_node_map() {
    echo "nodemap=["
    while IFS= read -r LINE; do
        local D=${LINE%% *}
        echo "\"$D\"," 
    done < "${DEST}/all.dat"
    echo "];"
}

extract_all_json() {
    if [[ -s "${DEST}/nodes.js" ]]; then
        echo "- Skipping node data extraction as '${DEST}/nodes.js' already exists"
        return
    fi
    echo "- Extracting node data to ${DEST}/nodes.js"
    extract_viewbox > "${DEST}/nodes.js"
    extract_domains >> "${DEST}/nodes.js"
}

get_links_in_names() {
    local DOMAIN="$1"
    : ${I_CACHE:="$2"}
    : ${I_CACHE:="$SVG"}
    grep "class=\"id_[^ ]* id_${DOMAIN}\"" "$I_CACHE" | sed 's/class=\"id_\([^ ]*\).*/\1/'
}

get_links_out_names() {
    local DOMAIN="$1"
    : ${O_CACHE:="$2"}
    : ${O_CACHE:="$SVG"}
    grep "class=\"id_${DOMAIN} id_[^ ]*\"" "$O_CACHE" | sed 's/class=\"id_[^ ]* id_\([^ ]*\)".*/\1/'
}

extract_domain_list() {
    echo "var domains= ["
    extract_all_raw | sed 's/^\([^ ]*\) .*/"\1",/'
    echo "];"
}

links_to_ids() {
    echo -n "["
    local FIRST=true
    while read -r L_NAME; do
        if [[ -z "$L_NAME" ]]; then
            continue
        fi
        L_INDEX=${DOMAIN_INDEX_MAP[${L_NAME}]}
        if [[ ! "true" == "$FIRST" ]]; then
            echo -n ","
        fi
        local FIRST=false
        echo -n "$L_INDEX"
    done
    echo -n "]"
}

links_to_ids_grep() {
    echo -n "["
    local FIRST=true
    while read -r L_NAME; do
        local L_INDEX=$(grep -n "^${L_NAME} " "$DAT_POS")
        local L_INDEX=${L_INDEX%%:*}
        if [[ ! "true" == "$FIRST" ]]; then
            echo -n ","
        fi
        local FIRST=false
        echo -n "$L_INDEX"
    done
    echo -n "]"
}

prepare_mapping() {
    local GREP_CACHE=$(mktemp)
    grep -o "class=\"id_[^ ]* id_[^ ]*\"" "$SVG" > "$GREP_CACHE"
    local ID=1
    while read -r D; do
        DOMAIN_INDEX_MAP["$D"]=$ID
        ID=$((ID+1))
    done <<< $(extract_nodes_circles_raw | sed 's/^\([^ ]*\) .*/\1/')

}

close_mapping() {
    if [[ -s "$GREP_CACHE" ]]; then
        rm "$GREP_CACHE"
    fi
}

extract_linked() {
    echo "var domains= ["
    # wired.com -1063.7798 27.971643 5.0 [1337,1338,2129] []
    extract_coordinates_links_index_text | sed 's/\([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\)/{d:"\1", fs:\7, x:\2, y:\3, r:\4, in:\5, out:\6},/'
    echo "];"
    
}

extract_linked_mapping() {
    prepare_mapping
    echo "var domains= ["
    while read -r TUPLE; do
        local D_NAME=${TUPLE%% *}
        local D_INDEX=$(grep -n "^${D_NAME} " "$DAT_POS")
        local D_INDEX=${D_INDEX%%:*}
        local L_IN=$(links_to_ids <<< $(get_links_in_names "$D_NAME" "$CACHE"))
        local L_OUT=$(links_to_ids <<< $(get_links_out_names "$D_NAME" "$CACHE"))
#        local L_IN=$(get_links_in_names "$D_NAME" "$CACHE" | tr '\n' ' ' | tr -d ' ')
#        local L_OUT=$(get_links_out_names "$D_NAME" "$CACHE" | tr '\n' ' ' | tr -d ' ')
#        echo "in $L_IN"
        # TODO: Move the sed outside of the loop for better performance
        echo "$TUPLE $L_IN $L_OUT"
#        sed 's/\([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\)/{d:"\1", x:\2, y:\3, r:\4, in:'$L_IN', out:'$L_OUT'},/' <<< "$TUPLE"
    done <<< $(extract_nodes_circles_raw) | sed 's/\([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\) \([^ ]\+\)/{d:"\1", x:\2, y:\3, r:\4, in:\5, out:\6},/'

    echo "];"
    close_mapping
}

# Cloaded loader-div
get_linked_footer() {
    cat <<EOF
var loader = document.getElementById("loader");
if (loader) {
    loader.parentNode.removeChild(loader);
}
EOF
}

create_linked_json() {
    if [[ -s "${DEST}/linked.js" ]]; then
        echo "- Skipping linked node data extraction as '${DEST}/linked.js' already exists"
        return
    fi
    echo "- Extracting linked node data to ${DEST}/linked.js"
    extract_textfont > "${DEST}/linked.js"
    extract_viewbox >> "${DEST}/linked.js"
#    extract_domain_list >> "${DEST}/linked.js"
    extract_linked >> "${DEST}/linked.js"
    get_linked_footer >> "${DEST}/linked.js"
}

# A JSON without links-information
create_alternative_jsons() {
    cp "${DEST}/linked.js" "${DEST}/linked_full.js"
    sed 's/\(^{d:[^}]*\), in:[^}]*, out:[^}]*}/\1}/' < "${DEST}/linked.js" > "${DEST}/simple.js"
    sed 's/([0-9.,~-]\+#[a-f0-9]\+)//g'  < "${DEST}/linked.js" > "${DEST}/linked_no_lines.js"
}

copy_files() {
    echo "- Copying files and applying template $TEMPLATE to $DEST"
    if [[ ! -d "$DEST/resources" ]]; then
        cp -r "$SCRIPT_HOME/resources" "$DEST/"
    fi
    
    unzip -q -o -j -d "$DEST/resources/" "$SCRIPT_HOME/osd/openseadragon-bin-${OSD_VERSION}.zip" ${OSD_ZIP%.*}/openseadragon.min.js
    unzip -q -o -j -d "$DEST/resources/images/" "$SCRIPT_HOME/osd/openseadragon-bin-${OSD_VERSION}.zip" $(unzip -l "$SCRIPT_HOME/osd/openseadragon-bin-"*.zip | grep -o "opensea.*.png" | tr '\n' ' ')

    NODES=$(wc -l < "$DAT_TEXT") EDGES=$(grep '<path ' "$SVG" | wc -l) ctemplate "$TEMPLATE" > "$DEST/index.html"
}

###############################################################################
# CODE
###############################################################################

S_START=$(date +%s)
echo "Starting processing of $SVG $(date +"%Y-%m%d %H:%M")"
check_parameters "$@"

if [[ "true" == "$RENDER_PNG" ]]; then
    create_png
elif [[ "false" == "$VIPS_ONLY" ]]; then
    if [[ "false" == "$RENDER_TILES" ]]; then
    echo "- Skipping rendering of PNG as RENDER_PNG=${RENDER_PNG} and RENDER_TILES=${RENDER_TILES}"
    else 
        echo "- RENDER_PNG=${RENDER_PNG} specified, but with VIPS_ONLY=${VIPS_ONLY}, a PNG is required and will thus be rendered anywat"
        create_png
    fi
else
    echo "- Skipping rendering of PNG as RENDER_PNG=${RENDER_PNG}"
fi

if [[ "true" == "$RENDER_TILES" ]]; then
    create_deepzoom
else
    echo "- Skipping rendering of tiles as RENDER_TILES=${RENDER_TILES}"
fi

if [[ "true" == "$RENDER_META" ]]; then
    fetch_dragon
#    extract_all_json
    create_linked_json
    create_alternative_jsons
    copy_files
else
    echo "- Skipping rendering of metadata (nodes.js, index.html and supporting files)"
fi

S_END=$(date +%s)
echo "Finished $(date +"%Y-%m%d %H:%M") ($((S_END-S_START)) seconds), result in $DEST"
