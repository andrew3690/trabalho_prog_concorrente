#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
cc -std=c11 tools/wrap-function.c -o tools/wrap-function \
  || echo "Compilation of wrap-function.c failed. If you are on a Mac, brace for impact"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

if ( ! grep -E -- '-[0-9]+' grade &> /dev/null ); then
   echo -e "Grade for $BASE$EXT: $(cat grade)"
fi

cleanup || true

exit 0

__TESTBENCH_MARKER__
�      �<�V9���O�B���pI`�N�3��lr��4��{cw{�ہ��g�}�y��*I���|���vKU�R�T*I�y^r�7\�:���u|66���S�����F�����7��������c)N� �}ƾ�G��	����/Ma���獂o�����z��%���ڷ'���텎�>Ps����F#��kk�߱��T?;�?���g����zi�҇��w��]���a���(�>89����糁3��q��۬�s�-��_Y�]l�p�](���Xm�u�	�xo��k$�s�����VV�7N��2p��Eu������!+'�M�-��j�������=��>
8��KT+����i��_�=H8�aD��Fsm-3��덧��i�q{�i���x+Ý���;�U:�?r.�y>��7�Urܐ�7V�O`LT`���*�������+ dn��On�-��0��!�A>�=��ϫ���)�~��PR�����בD����v\��U/�^>��we�,d�ڬ�21M��p`����b��d��-W��Y�jSX>���"�$� ��6��|�Uo��x����a�U@� ő��kyS�>���	��l�#`�ę�_e��(�q�Cc)*f�*�߸7P�e�P"P�%��U�'XN��6@ehi��7,��U��n"��ys[��Жe��U�%P`�ٳG#�g4��z#�Đɖ�;�k��� -���@	4̸�A��``z�/FԒ*K3,�f^��7Y��0���K�e���N�ɔ)LFS"�0dF����ӡ�R�+y���E#�r��& ��?��CvQ1���o����^Y������;?��_�fF�����?~������hҬ�=\4>��W�x"&[�!��6	.��3��4�~�델�N'��EJ��-����"#~�?F,�x2������g��p��?�%�z�:�-��;�}K 2���/�n�BcH�N��� 8mlp�9�1+�а>8�Cn��m��դ��XۖD��x3���^��T]$�`v=R�QE�i�KM����T�B=�X$��&�Y��&C&�l�5��yb�Kѫ|����HZ��{��P�hN6��D">1G��O�M��5�zq��󓕳)����+$c�Se'�7V�c�s����_�:�:���!9�� ��H�*XNa]sN; a]N�4�I,7Nl��D������Ksμ�:�k&?Yb�����JҜ�����-�
�x�G� (�eՉ矌�����N��(ːyp��,]�C��шp!�i��pȠ��Y_A4�#��^ZBͲ���"�*4�D�R׻��P�j��j�]{!�Ao�<n����4�~˧9¾.k���mH̀�&iQyϛ���+���f�%b�y��6h��V�l@2�O~�=�5�\	3=���P����8 ��9�X�mvm$�Z�1۠����e�fC��@���֕�M'��ڎ�-7�^Ffol��!�AZ���xM'K@��p��wgl���{6���WeMh�Hѷ��ξ�3��07��7��:u|�g�_B�¼�9�v���"D9�#��R��:���	1OH^W۰����?��T�����t��+�4+H��؋���\��r[J��.V���=�Jg^��-mr�p�"�S��/��'���A�K -�:��쟪13�`wR��b+Hh�"�Y�m��Je=l�=+�./��u��Ҿk#(%���Ɣ�%�Eb����y�	���0�l]rZM��Z
@S �U���y�$�<E0�WHQ�"�ʓW�/hz���o����W���k�	��y�����������ߣ$�����>��w����fi���Q���?���7�ŵ��Ng��ݽ_ڋ�%TVsYyQ���d��?���шqN�_�"�T�s���	[������?l'��t/��$���  ��!�8`|�������X�9Y(L�o�}w�6��7�y+++x��+�?>OL�<���l�N�+ֻ��g Up�9�ٺ�	���W����ENdԹ��)X�RF=2k������+��б9��ʌ����������қ����u��K��R��{�T�3��o��\Y;�
��	�uI��嘀�A��۠�|1���K��i%���w��Tn�.���1RYbLG!-xѿ�x>�����������n�_):��a��=cC8�?u�Y��EpA���:C06��qaaa��U�&4q����ڀ5X���Cn���6p��^I�,�Z@�h��mg��ˋ��`a%f�J�,��c뢲5��� �TNw̫TQ�bB�)(Z|G3�h��,L,��1r�ҁ҇�w1�����I�OF��ˉ����1��$�P�,TKg>�J�+ ;x������=�E�l� �8���N��$�F��
$��@R��˥%ђ5T��M*�E��*���a��]v^~������j�-�b������D���6�2�.�e!�{c���2�^��&(,�I �Z�u؋`�|�^_]�za��N�P�����wN��9uF���ϵ͍����Hq��GN�=������_�fs3��X{��#-8��̲�u��`�{|bu;�ݟ:G{?[?[Vi�N��dt��g#�ҁe��x1�؎4�
/-<�4�g
R���g��'��P�{_��B5O&�ư��-�&^��M/���<t�i�g�<�Q��8� ���u%(0>텴&��h/����6�Q?Cl���+&��T!�71R�A�A��|hb�H#@��OVfTXQ�r;�0O�rO��fN�����S�<���)����xFN��[fsS�(���`��#��74�����bkdg'��9FBP�_+�ǓW�8��b6�
��j�:t�U�$&�����K�7*��4���P�*�F��a�2�����B�EB�Z(�꼺��:�Q��9��"~d-��D�`��H����q�Rhr*�O�ä������o�62��)��Q��i�`X�_�}�M���A�Gɼ�� v2ol���`�L"��뱖�>Ml<�����`S�]	���C"�x0qܑ����F �y��cXuw� d�=̅88:���)��ƒ>����*t*E�O��ݽ)�Π�?��1���i!��T�5	����T 	e�ac��Đ%��HR �$�/j�v�X�4��,*�ܔ�\0+��/��']'q��pg/-��ĢS5l�3jO��K�I�!g3�(�iTI:������4M�	&�8��y=�\��7!"�.���8y0ZUA�zg.��Ty��͌�S	Y�(�E�7jU �P�G���£�(� !@Վ�'"��|�;One�|Q��3q@w����E.UYJ�}^~ඛ�G����/�b�,���f�"��s::Y&�I�r�6�T��-���z"��,Tb� l��ȣl�.J�D<��
~`u����6o��Ne�"Õ�+�¼C#�>ͨ�3{A	�����؁�_�B1��c1h3��y0�)�b�U�ET[3�����|K�(��B����L��"�M��H�2�H��J��F"FU���[�����`�����(�'��� ��6��xlь^ϹI���YP'j�&^D�"X��8��PeA_�	a��QSU\�4�#���0�g�n9�Ig�c�#I ]u�ZH&Z/ʊ��tC�.w��l
%c\��A�3Q��NV���S�+�UP��7�-�m>��S����Ł�N �X��4-�f�2��y+jtm�ԗ�@:gr+���Ʌq!RU =�s��q�m��̨���z�YW<Dc�����G��㣃�*&��a�,�D2��k��rr��g��W�:׻�&yN� P�&��d���-��sqP�o*��Kg���m��a!0��x�@�T��j���KC}(%�t���12&�m��t��[`���!��e�J�Y@�����X�Q���V VC*���v_�3�N[Ӝ�p���o��q��~��Q����G�?��1�|?��m��>�;��d�LV�����v����?EԜ�]@��M��z8�L��~-c�H���M���m�Ӏ=��p�s����eٿ��H��6�s��Tq��p�\���`�O�l�s��g��ke8���c�/ԵG_+?�ǯ
g~�u���Fd�]�1��������[3�iiHP�%jq��!W{���6��1_�B�n0al�� �_h�We���������L�v^Ef0���
�.h򗌷/WZU�l��Z��4U���؄������Ѭ�����͗��X�7��|����ښ$��Ro@k�U�����M|l�ܤ�o�l�ܠǚx4r}�=֛�9�Gȴ��k'q�&Sj������Kj���c�I��$�D�����s[����U|��.| ����{j ^� ~��3�B�
%�B�	�A�����3�}p0�8���UH�~�&�W����2"z��ZVU���F|�3u�Sz:�\K\!�S�� X� 䨁�|��Z��c˯:��G�w;�Ԯ�M&g͋X�g�ļ�m����X�wl�!"��2]��nֺ�>���|�[�筞��G���'}�run����пY��ɰ�8�.�:��]f�n��H$?|�l&�bi_�,���/�{��abԈ���ɓf�(�ĭKU���YD�I|�'��ƅ����Zqs��2�X����j v�dW��奼�����a����66Z�����S�������蘰(�+P*8Nղ{CNG�1���8e�f^a���:'�_e��"���)Z��bȰ�s�߈/IX���o�508t�*~���X��ϲ{t�4���}��f;��St�5�S�Γn��`d9�
U:������́�  ��J��v�h9���+�/Scnc�"A��wԼ+~�D,��"q{w�"�C���o��G�G
TuI�������5�QE*�8�
f��ᾬ����|�I��/H��zV׹�b ��~�̷SdB���y�����"%��H`�Z3��~Jir��v���T�?���y�S>O,�N�] R#*N9*�?6wC�~���F� ���Н7Vky��C7b)3�i�>���CG>��*�g��a���5֚���-����������!�6�X�!�����9�c~OC۱���Li���?����co�Y��t;{�ξu|��^4�O���e�T?8n߻��n�m�����4���Z`�h�J� x׵��m�Ճ�!����sܜ��T����	ˍ K��J����I�������c������Ŀ�n�&y�6�:�����ސ9�E#bVk5��e{�1s��ۻ�#�
(�G_]��O����~�>^�C�����:[��ַfu���7�����v>�������קm�zڱ>��5yɬwǧ�=�����^�ݬ�_�_f�a�����{<>v�e�h�?���fs=m���'��)o�����Igw�p���S�5{&��FjL�x�8�	�����T�ܵ���_{I�"p���t��<�@����f�@���|���ֶD`��� Ѷ�
���NB&:<f�]Z�i��Պ�_UV��j�
+��@ʏb�W���~W�gn��I�5�3p\ϲ/=?�	��| �9��b � ��Q�w�"w<)�i^�;�:�B�~�,��������#.�h�d��
E�5X���̂�e��#a�S���UP9 W�)�H*���ԏ�,W�ބ���M������2r*�!�QM�X>E��.��$����gUaPt/:E����=xP�Y`�OVAg�����0:�>G�5F*���K5������g��s�k������kl<�����.<E3VY����A������������$n��19B�L �%����a֧�����m�Ƀ3��잳���_��Uz��V?���}v'�[*U�J��TU�^x�-,?&��8!N�}�����U�>7T���Oa�m�U^*������^OOa����I��4���Y&�t�ɐ��	-�?mX]���2Nr]-i�WE[��Y�@B��"�C�rQ��C��ǉB*f1P�T��sXd�3�afC�Q�j��z���p(��G��eeS%�J:S�^�F���A��[`Pq�viT�J��	�z��sK"&�gt�=C,>�1F�9����?�К]�9ܠ�}d�2|OA��m�Z���e��cX�s-����`��Gg��`oV3��(�W)���#n��[����_�pGɲ��'*$�,���;r�$�v��%�_T9`�7����A�ux�������_��_�����R}�
��� �cG�֞$q�o3����W����x*|��+}��=m�8��`,'ԛ���^+r&J��0���'�u�ս��5��&�@S�Y�� E_��A�pȔ;P�dJU�$W�
O�u����?y�;5��:sWb�)gS�E6�p���A_9W~���C,W�N	't���c����e(��b��v�kXs�)�Jflg�8O�i%m�����`(��!HS��t�T?"� @ŭRQ�ʥ�	ٸ��YJ�dőFO�=���Qsj��2�RlʨRB�m+L���7U.���
�E �fE�|C(	�9&ʸ��ܭ+��5F�4T1$
�ص�f��LC	�`��c�BQ-��RFMHץ_�](��"�qoΦ+�F䷣�cP�a�f�J�X�(�e̝z����4ȅ$_�M21:�4
I�0���ՌZ*�a�,��f��D�a��GX���	��J��0.�oalh�qM�*��ʇ1-��RӀ�<n��x[��+��nm�2���\?.殸嶂��ٹ5٩�o�ξ�!�M�$Q:.�es�<S{%=b5�L\��P�eng5�Q�n��D)�����(��+�(�F�¸�X��cXh�(�k@�2rѲ�ʅ�ME[Xx�٨XV�����,g+(����0W�����K�v&j�ӫl�����m�D�iAy����ϻo^�+WR�ێV\l�ײ�qD�������]�F���F8���I���yٱQc���0#X*l�8W,��#|V*�l�<�Hg��<���b���}�������oy�u)���a���t�w�������AQ�B3�1�܊d`��ϩx^��?D�����0"Tאe蓟�~c�D���"̙���gĈ4��R�ϳ�Н/64Ou�p�ظr7�޺�U�Y=�y{����o�v�]�rv��V9X�V�A§z?P��@�`��Ḧ́djC�"D�Q��%��t�)S"�}f�{
�kGnd ه�u �s�AT˂�?5}�����	jF<��f����K�6Y���ܽ������)L̘�s��٤���ka�7�\�*�X(�L#\dvw�F�
3`���Ym9\l:+��bXU[����:'s�:r��j�E�EZ�L3�j
`*�1u�1άhËfˇ;/���iG���e�	��.ǆ##OG�p�+������$��S�ɣ�=I;W�� �lI[r�z-�5�j%����qRк�O��vD>�d��w�W:��&����n8b&���iC$1d����#�eC�������0�@�R��B��ːSE8�0ќV���o$���8�����y�/d�qD�0/��>+�:�Yt��u{R�ڈ�ͻB��⠖s���\�����N�ܗ9Fj�ž����[�<�=f����I���&�GUW��Q6��`��iΈ(�<\!FH	��9gQP��=ʄ
��{W�V��&g�Nte^*/\S����ZT���>�a�����'^���QH{C+�p�����eu��U�:�K��S��]Hp��i۠�V!A3���t_��0�=��<�yT)��6s.�s��A�2�c=i0�ݰa5sJs~�w�
�	�Y�M�o;��'|)�u|���)��]t�|��"��.��%�R��=���$�����:�؏�=G������Q��J�v���"�M��Db��x O�t6�:M��`�1fA�-�a/�W��Ҏħ����t+>��Ƃ���'�����}*>� �D�2�Xv�3'7�Ր��	��Cvy�dm̼�A��T�z���6�y��&����*����R��`'�����إvVqu;v��9�PK�e��U�l��15�ԗ�^��y��;�ri�+�l���C�
���=̱��
�\�vꞢ�|���v�%u�VG���0 V-�\�lvmY��(7ݑ��dˁ6�x<�u�YZb�!�JP��,Z.hP/m�{"��D��,v!����6�2L��̣ͮ�d�+w�RH+uL���·�������n�4���Ҹ���F=���9o��*�b)$�s�X&`�c���
I��l3=qr��Ze�')��W��jb*���֥Séli��>�"�糧4�ݣ[�4*wQH#%g�:mǡ�uZ���Y'�e%�eh.c]�ة�`�d�~<��cU�Q�ACH��5B}9��@�W�[�0��$�{ ^ȹ�!ќ���b�*{v�g"z��]k�Қv��ך�+'S��&�9�;w��5�:dZf�j���6iR#��3Rc3�,�� 7��q�����ϵ]������;��p�e�r�&�l����S�>0WsP�7`ł-�7wV�F�
-��hf�rϭ@����)��O�L�3v%N/$�m�U���,�����an�ը�3�Ub�b9�����w�TҐ=�)�O>#5���[�z���;����K��o
�N-�4�[��з[�>]ՅC?��9�K�&��r�,�
���r�46c*��И3{n$9j����ػwIF���8�����^%k�6�}LҸ�u��3�nAO�����_�6����	�z��8��0��e�p+� �2��/ƭM\��b�a`�P0S����@�6�����dJ����59SL�Rb8��@�ȍ���r)�⠉8K{_$�7��J���� ���LVI����$)O��P����N���ͧI#氬�3��G�1��5z�B$�T��ݼ��Xz���`��V��t��l���*H�6OC��z���(���#�!L�`�����۰ K��N1U��f�,�Zn�[#)�ECﬓ��=�/?c���0-EI�Q�S���X�Nuwlr�}4.'RKp&6�9c�D3e��0IQ~N�i >Z�}�䜇ZP}p�`�ՠ�Ή7����\x�^�2�)�f�]���t|(�����*8������-Oҡ��_��#�]\6:To�?H�r��ހ~|vU�k�L�j73%�bQ΅�����Ue0'������n�tdf{�AM:��?��r���bJNXl���7e�,��^ `��U:�/�S
�J\�N��2���|�����]A4��:�ZB�� ��dT��<jfֹ�[-�U�88R�d�x������c�d�g���4I����()���P�*r�V���a����*n��^m���E�s�M����*t�R���nnM߆v�F}���M��i��i���;|���n)RbM_�ҙew��v����9҂`�Kǚ&���ڪߞ�!#Fֈj�����9V�:�<���6�Up^+�W[q���=�b��\'��2�B�v�WJ"1�GB����@:Q���E�e^uۀ㛮�pp*,Dţ�X0>�|4�A�:}ί���ZCyJոk��ӆ2Q|��N��h������i?�.�.�`�+1�]��/��7�(Wv�%-����w��|�������D���0����Z2w�N�g��y4�]ֽ���#�u^�*N��#�3����(��9�vʤ�"�*a�\��?��d��	m!&RV���n�`��)F'�8HS��+k��*>v^0�/ug�Vb�'����E�m��V�MFkUNz�Z�X�M��l��}�Q��QYFb��"��3C���M�l��K�/��r����m1�zΪ5[]Y�)կ�9�o�=P��]_[@iQH�z-D_/���6��З&�L3}Y�2��M�Cc&m�����������w������z��X��[�7�i%�+[�i�5.y�Y0�r������dM;�/h�������\�w]˔���	//���Z�_�Ȋ,�L,�aP3 ok�_�;��%'p���������' �y���:	N��b�a�(�[N:�w���	A�+,����O�q��4��]i�T�%�S'L�F����b&� ��W��(΂�e������Y�`�e�- Y�Y�ɼ+��1<�k��Ͽ�S<��������㇙�_=y4��o�)��g���֒Q@�����cĢ�@1jjm��gc]u�A�|l, �n7�o�H��Y�⒣9+� �v٢(N�#������a�bqh����#ǀ��_�}K���4%���'�o>�"=�Q#��w᫰-d��ar���9tt���;[/���Lk�4&�)�S� �;j�2��sf�9�Z�Z�OeuuK.�o�~���=���ܕ�8�;2�Y{sC1�Ϣɰ��>�6�D�Z�� c�DaW�Y�/��t�@*\WO�'P4�B8���K������Ny&z�<��}�<�?V�u��݆Y�w:nDcB	�ƒN����
o���Wལ8R����t5d)��H��΄"=��S������"�Ek��N��0{�6+�����JF6�=�H�)�������+<�����Z��6�6J�?x�ߣk��o��^��8̟o�d�~+�ͮo����q��#�����o平�>��S/9wD�B�wϣ�8"'4C�"K _���I�#����`6H��z�}V���{|��x�{_ �g���/���`�u�;�E�W���;�vh��P��|�gs�Fi�Q�U��K�(��A�9�y����d��BZ-(�'/ #�D	XC�����k{������.�|oH6A��G��3�v �J�;K��,�HƄ��kO�Ȫs0: ))�䎬�(�M�ϝ���W�[�;{��6�*���A�wZ�/ Z[R��ȃgw��]�`w{si�S�����;�_�j�AB����=K�%�ߞ�O(�����f�C������x�a�������~w����,��=b�F�����= ����&��|�>@|��j��<�a�rFNj˭g'�Y�u/�k��,�;���ǖ=��	H�'���Iku��,���{y$#��V������I��p�۫�g�6��L�Hm�,Ϋ�2��q�&~��'�F�5���"��k���!�\����̿�=�E�z��Q���Ŷi�;��K�@悀f�ȏi����"�(�)�(&�@6�=X���Vk�'�#X��ӝ���j�Þ���|%	��ʑ��5��Ъ�N��� ���_�7.����U�����S Y���Ŭ (�_8G�/���#��	
�P<�lU� p<�@���ᴴO�r�@����y���M���	eb�`ⴧI��!Y� S�#���	�������Qą����@��?�"R�l��0�$�n! .R���!:���0P�����i�t� ��T�����A�!@u�G;�C�?��V�:�)�/��>�e�oЏпj�Ԯ��lQ-��0u"F�����OJ��� Ͼ����wk����dmn���C�~O'gg0{��I��1����h"J}k���L��/������'O�˞����n�I{Co|�9�5O��y�,��~����K��s�v�z��|8��e��\�ɣ������v�u��p7�U��ޫ��T��^���n0�h���I�vZ^�LQ��eS5�E���j1mՈ��Uq����N�?�2�����N*��@βL+t�aU��T��#��޾	W��v��ӨZZd푳��$9��Gq�C�����^D '�p�XI�A("<�����s�V��nc�F�
�j���t4P"pk"��o�ٴ������i������
�����N[B1d�y�>&�����p2���~4��S�Bg֖ ��ISX����[ʐ*�O2i�����z㫴m|��n$N��u���wOu1���r��R9�
ɉ!��<6�_{��D���N�u\zV��qG!�N�@�Γ��Q�u;>O��q��A�G㏕��R����P=�7��r�C��k*A'	�t؂�-��EZQ�eh��s˘M6�6�>\P�As1ME�YI��͵�*a� �N^\Y�2��ˠx��`�U�?ԯ)�y�>yoi�\ɯ3p�mj�#R^,��0 N�A�M���@+����\M8��۶�6ķ,�J��G�;�5��|v\	|x��G֦ty���r�MQP�6���$b)��c*3�hYCx?7�����u���`Gcf�T����ly��&�T4����s�Fh��~��4�o5��/��?���ec��=]2ӷ{�͚
K�i��b�7	G������ħ�g����zy9���,?�Y$�p�U��jd��H��	@qQ��?(�A�W��_�*�'m��Ĭn�h*��3��LRhY��R'ݰ�ꮤ��3��^�\��6I�����_�/D��q4�>��@���~�$�~�W�T^j���k�L1�L�K�0���&��i�`�DWkBL����ݴziÂ�S0.������K���ʅ �F�=����_�@��]`k���[�s?�S�U!Gm�;�.-Y��Ā������Qy�|�'�������(���VZ���O���m</^�m�:�'.��'��U'8����R}��m��	�>$�7Ǯ��*�uK�g	����z��O��d��/vh��������������qg{���Mt,�IЩ�7��p�ď/���y��ȇ��e�	�Y~�QBZ]�k#hJ�D@��-�燧��L����kNzL-Q/B(���3�a2��. �8p?M�g*����]�z�R��	=�=й~� ��/(�;�_W�Ô�^���	KB������cy���z���]�00h�)_0C�_ �q���yu���x<Zo��V���I7 4@k�a*�3޶׻��]���&��97�~l��!,Oљ�]r�{��1z�6_�ކ���_�Lz����q�uX>��|L��V횡�l�	y=�3�������/���� L~=����;[�;���s ,� ����	��_7�Ȕc���`�1n��h(NB��؜p���&9�>Q_e֝Tzx]�U�����M���j�p����ا!�#�b�w����u d䍓�i2&ˀ5kc���V@]�QF`�����C/i@Ódr����t�ф6�,�X�H��"�Y�C_n����Z��p����ǻ�o(^�6z;	� ��BqX�t���o$� 9~�?_т?lb9�� ��V Z��*��^w�Ihz�a�wA�)5 u�;/�w�;�
.���4�������й�t��M�
���2���`%A�)���4��أ��I��{�+@��m&x��u���%��Yu���u�p�K�8�
|�@�ʶ����B�H %��uQ��揃F��ͥ��j�N��r�ҏ�ZG���G��{Gpj����yy��GE���$����>�C`<�������P����*W�у��L~�����N����7Y�f�VXF���G1D��4��7��n�����X@��&�a#�_⋘���:�<)j|�	�Alxk��=��c^b�[t�O�A�*XG̀�''��P%��b���H�J��qB�����F��Y�%tORNe-��LgQ�Ն��B��j��EA�#!E��ا�R~�����P�2|������ :4O2RS(������bC�0JR�c� w��}xLF���7塚�G�q�~c��ч����=�F��"�O軞����*k�����w���8���.1��2h�f�d�u�4@h��w�Y(�1b�+p
J�_M��H_�v3"��Ȱ5|KN���,D�@���u.�8���b��U�P����%�qP6�y;a��6�kkD*\6)��M���v�Sg!�@�{'�Mc������p@]���l@j"���8���j��@_�>FQ��va�Q��>p�񻔐s��*]u���y�|Ū�.�
MEpה�s�.�c��:�塊E{
���(��1J���9��z�N:ٺ�B��-�b�l�l�1�
��$L��t�7Z�A�|w�O�]/�I�G`HBg��O�>��;������W����D�.�&����:�x,E_g��X���&!'5LًHzQ}��Kk҂�%�OjlZE�T�`$s�iL�w�ṗ�輼�#��Cj&����8	��-���M�?�8XM <�T'`%�}«��A�5ͧ!ǜp����`ö�[��_�x@���/-	��+Gmo�l�Y��i���#cXwy1��E����^�l����΋���G��@�J�j1X����.[��M�'Z�:.w�����Ly�2��?�4�F^<F��diB*k5��/Zȧ^�S�_Y���[�̟�3����?�g�̟�3����?�g�̟�3����?�g�̟�����?�oL� @ 