#!/bin/bash

# ======================================================
# Script Ujian Essay & Pilihan Ganda Otomatis dengan AI (DeepSeek V3.1)
# - Auto setup & sign in ke Ollama Cloud
# - Essay: Generate semua jawaban sekaligus
# - Pilihan Ganda: AI menjawab semua soal otomatis (68 soal)
# ======================================================

# ===== DEBUG MODE =====
DEBUG=0   # set ke 0 untuk nonaktifkan debug

OLLAMA_URL="http://localhost:11434/api/generate"
OLLAMA_MODEL="deepseek-v3.1:671b-cloud"
TEMP_DIR="/tmp/ujian_ai_$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TEMP_DIR"

clear_screen() { clear; }

show_banner() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}   Ujian Online + AI (DeepSeek V3.1)   ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# ===================== AUTO SETUP & SIGN IN OLLAMA CLOUD =====================
auto_setup_and_signin() {
    echo -e "${YELLOW}[Setup] Memeriksa dan menginstal dependensi...${NC}"
    
    for cmd in curl jq perl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}$cmd tidak ditemukan, menginstal...${NC}"
            sudo apt update && sudo apt install -y $cmd
        fi
    done
    
    if ! command -v ollama &> /dev/null; then
        echo -e "${YELLOW}Ollama tidak ditemukan, menginstal...${NC}"
        curl -fsSL https://ollama.com/install.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${RED}Gagal menginstal Ollama. Silakan instal manual.${NC}"
            exit 1
        fi
    fi
    
    echo -e "${YELLOW}[Setup] Memastikan layanan Ollama berjalan...${NC}"
    if systemctl --all --type service | grep -q "ollama.service"; then
        sudo systemctl enable ollama
        sudo systemctl start ollama
    else
        if ! pgrep -x "ollama" > /dev/null; then
            echo -e "${YELLOW}Menjalankan ollama serve di background...${NC}"
            ollama serve > /tmp/ollama.log 2>&1 &
            sleep 3
        fi
    fi
    
    echo -e "${YELLOW}[Setup] Menunggu Ollama API siap...${NC}"
    until curl -s http://localhost:11434/api/tags > /dev/null; do
        sleep 2
    done
    echo -e "${GREEN}✓ Ollama API siap.${NC}"
    
    echo -e "${YELLOW}[Setup] Memeriksa status login ke Ollama Cloud...${NC}"
    if ollama whoami &> /dev/null; then
        echo -e "${GREEN}✓ Sudah login ke Ollama Cloud.${NC}"
    else
        echo -e "${YELLOW}Belum login ke Ollama Cloud. Silakan login.${NC}"
        ollama login
        if [ $? -ne 0 ]; then
            echo -e "${RED}Gagal login. Script akan tetap berjalan tetapi cloud model mungkin tidak bisa diakses.${NC}"
            read -p "Tekan Enter untuk melanjutkan..."
        else
            echo -e "${GREEN}✓ Login berhasil.${NC}"
        fi
    fi
    
    echo -e "${YELLOW}[Setup] Menguji akses ke model $OLLAMA_MODEL...${NC}"
    TEST_RESPONSE=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$OLLAMA_MODEL\",
            \"prompt\": \"Halo\",
            \"stream\": false,
            \"options\": {\"num_predict\": 5}
        }" 2>/dev/null | jq -r '.response // empty')
    
    if [[ -n "$TEST_RESPONSE" ]]; then
        echo -e "${GREEN}✓ Model cloud dapat diakses.${NC}"
    else
        echo -e "${RED}⚠ Gagal mengakses model cloud. Periksa koneksi dan login.${NC}"
        read -p "Tekan Enter untuk melanjutkan..."
    fi
}

# ===================== ESSAY (AI) - TIDAK DIUBAH =====================
parse_soal() {
    local html_file="$1"
    local output_file="$2"
    > "$output_file"

    awk -v out="$output_file" '
    BEGIN { RS="</div>" ; FS="\n" }
    /<div class="mb-3"/ {
        div = $0
        match(div, /name="jawaban\[([0-9]+)\]"/, id_arr)
        if (id_arr[1] != "") {
            id = id_arr[1]
            sub(/<textarea.*/, "", div)
            gsub(/<[^>]*>/, " ", div)
            gsub(/[[:space:]]+/, " ", div)
            if (match(div, /Soal [0-9]+:[[:space:]]*(.*)/, soal_arr)) {
                teks = soal_arr[1]
            } else {
                teks = div
            }
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", teks)
            if (teks != "") {
                printf "%s|%s\n", id, teks >> out
            }
        }
    }' "$html_file"
}

generate_answer() {
    local soal="$1"
    local system_prompt="Anda adalah asisten AI yang sangat patuh. Ikuti semua aturan berikut tanpa pengecualian:
1. JAWABAN HARUS 400-500 KARAKTER, TIDAK BOLEH LEBIH ATAU KURANG.
2. JANGAN GUNAKAN ** atau markdown apapun. Hanya teks biasa.
3. Jawaban harus mengandung semua kata kunci yang relevan dari soal.
4. Jangan menyebutkan kata kunci atau kunci jawaban ideal. Langsung berikan jawaban akhir."

    local user_prompt="Anda adalah asisten AI. Saya punya soal essay tanpa kunci jawaban. Sistem penilaian dosen menggunakan: Cosine Similarity (60%), Coverage kata kunci (30%), Length Score (10%). Karena kunci tidak diketahui, bantu saya dengan strategi berikut: Analisis soal di bawah. Buatlah daftar 10-15 kata kunci yang paling mungkin menjadi acuan dosen (istilah inti, konsep utama, nama tokoh, rumus, dll). Tulis kunci jawaban ideal dalam 2-3 kalimat minimal 400 karakter maksimal 500 karakter yang mengandung semua kata kunci tersebut. Lalu tulis jawaban saya yang harus: Mengandung semua kata kunci (coverage 100%). Menggunakan kata dan struktur kalimat yang sangat mirip dengan kunci jawaban (cosine similarity tinggi). Tidak menambahkan informasi di luar kata kunci. Jangan beri tahu saya kata kunci atau kunci ideal, cukup berikan jawaban akhir saya. Panjang jawaban akhir 400-500 karakter, maksimal 500 karakter gaboleh lebih, kirim tanpa format tebal jangan gunakan ** cukup murni text biasa. Soal: $soal"

    if [[ $DEBUG -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG] Soal essay dikirim ke AI:${NC}"
        echo -e "${BLUE}$soal${NC}"
    fi

    local response=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$OLLAMA_MODEL\",
            \"system\": $(printf '%s' "$system_prompt" | jq -R -s -c .),
            \"prompt\": $(printf '%s' "$user_prompt" | jq -R -s -c .),
            \"stream\": false,
            \"options\": {\"num_predict\": 150, \"temperature\": 0.7}
        }")

    local answer=$(echo "$response" | jq -r '.response // empty')
    if [[ -z "$answer" ]]; then
        echo -e "${RED}Gagal mendapatkan jawaban dari AI. Periksa Ollama.${NC}" >&2
        return 1
    fi

    answer=$(echo "$answer" | tr -s '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ ${#answer} -gt 5000 ]]; then
        answer="${answer:0:5000}..."
    fi
    echo "$answer"
    return 0
}

generate_all_answers() {
    local soal_file="$1"
    local -n answers_ref=$2
    local -n soal_texts_ref=$3
    local total=$(wc -l < "$soal_file")
    echo -e "${YELLOW}Mulai generate jawaban untuk $total soal...${NC}"
    local count=0
    while IFS='|' read -r id soal; do
        ((count++))
        echo -e "\n${BLUE}========================================${NC}"
        echo -e "${YELLOW}[$count/$total] Soal ID $id:${NC}"
        echo -e "${GREEN}$soal${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        echo -e "${YELLOW}Menghasilkan jawaban...${NC}"
        answer=$(generate_answer "$soal")
        if [[ $? -eq 0 ]]; then
            answers_ref["$id"]="$answer"
            soal_texts_ref["$id"]="$soal"
            echo -e "${GREEN}--- Jawaban ---${NC}"
            echo "$answer"
            echo -e "${GREEN}Panjang: ${#answer} karakter${NC}"
            echo -e "${BLUE}========================================${NC}\n"
        else
            echo -e "${RED}✗ Gagal generate untuk ID $id.${NC}"
            return 1
        fi
    done < "$soal_file"
    return 0
}

show_all_answers() {
    local -n answers_ref=$1
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}RINGKASAN SEMUA JAWABAN:${NC}"
    for id in "${!answers_ref[@]}"; do
        echo -e "${BLUE}ID $id:${NC} ${answers_ref[$id]}"
        echo "---"
    done
    echo -e "${YELLOW}========================================${NC}"
}

submit_answers() {
    local pertemuan="$1"
    local mk="$2"
    local kelas="$3"
    local -n answers_ref=$4

    local curl_cmd="curl -s -L -X POST 'https://belajarpandai.com/user/ujian.php?pertemuan=$pertemuan&mk=$mk&kelas=$kelas' \
        -b '$COOKIE' \
        --data-urlencode 'pertemuan=$pertemuan' \
        --data-urlencode 'mk=$mk' \
        --data-urlencode 'kelas=$kelas'"

    for id in "${!answers_ref[@]}"; do
        jawaban="${answers_ref[$id]}"
        jawaban_html="<p>${jawaban}</p>"
        curl_cmd="$curl_cmd --data-urlencode 'jawaban[$id]=$jawaban_html'"
    done

    echo -e "${YELLOW}Mengirim jawaban...${NC}"
    response=$(eval "$curl_cmd" 2>&1)

    if echo "$response" | grep -q "hasil.php"; then
        echo -e "${GREEN}✓ Berhasil! Jawaban terkirim. Redirect ke hasil.php${NC}"
        return 0
    else
        echo -e "${RED}Gagal atau tidak ada redirect. Response:${NC}"
        echo "$response" | head -n 20
        return 1
    fi
}

generate_docx_report() {
    local -n answers_ref=$1
    local -n soal_texts_ref=$2
    local nama="$3"
    local npm="$4"
    local mk="$5"
    local kelas="$6"
    local pertemuan="$7"

    if ! command -v pandoc &> /dev/null; then
        echo -e "${RED}pandoc tidak ditemukan. Install dengan: sudo apt install pandoc${NC}"
        echo -e "${YELLOW}Laporan tidak dapat dibuat.${NC}"
        return 1
    fi

    local filename="${mk}_${kelas}_p${pertemuan}_${nama// /_}_${npm}.docx"
    local md_file="$TEMP_DIR/report.md"

    cat > "$md_file" <<EOF
# Lembar Rekap Esai Belajarpandai

**Nama**        : $nama  
**NPM**         : $npm  
**Mata Kuliah** : ${mk^^}  
**Kelas**       : ${kelas^^}  
**Pertemuan**   : $pertemuan  

---

## Daftar Soal dan Jawaban

EOF

    local sorted_ids=($(for id in "${!answers_ref[@]}"; do echo "$id"; done | sort -n))
    local nomor=1
    for id in "${sorted_ids[@]}"; do
        soal="${soal_texts_ref[$id]}"
        jawaban="${answers_ref[$id]}"
        cat >> "$md_file" <<EOF
### Soal $nomor

**$soal**

**Jawaban:**  
$jawaban

---
EOF
        ((nomor++))
    done

    pandoc "$md_file" -o "$filename"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Laporan Word berhasil dibuat: $filename${NC}"
    else
        echo -e "${RED}Gagal mengkonversi ke docx.${NC}"
        return 1
    fi
}

menu_essay_ai() {
    while true; do
        clear_screen
        show_banner
        get_cookie
        echo -e "${BLUE}=== MODE ESSAY DENGAN AI (DeepSeek V3.1) ===${NC}"
        echo "Pilih mata kuliah:"
        echo "  1) RPL"
        echo "  2) PBO"
        echo "  3) Kembali"
        read -r choice_mk

        case $choice_mk in
            1) mk="rpl"; echo -n "Kelas (h/a): "; read kelas;;
            2) mk="pbo"; echo -n "Kelas (a/d): "; read kelas;;
            3) return;;
            *) echo "Pilihan salah"; continue;;
        esac
        kelas=$(echo "$kelas" | tr '[:upper:]' '[:lower:]')
        if [[ "$mk" == "rpl" && "$kelas" != "h" && "$kelas" != "a" ]] || \
           [[ "$mk" == "pbo" && "$kelas" != "a" && "$kelas" != "d" ]]; then
            echo -e "${RED}Kelas tidak valid${NC}"; continue
        fi

        echo -n "Nomor pertemuan (contoh: 6): "; read pertemuan
        [[ ! "$pertemuan" =~ ^[0-9]+$ ]] && { echo "Harus angka"; continue; }

        url_get="https://belajarpandai.com/user/ujian.php?pertemuan=$pertemuan&mk=$mk&kelas=$kelas"
        echo -e "${YELLOW}Mengambil soal dari $url_get${NC}"
        html_file="$TEMP_DIR/soal.html"
        curl -s -b "$COOKIE" "$url_get" -o "$html_file"

        soal_file="$TEMP_DIR/daftar_soal.txt"
        parse_soal "$html_file" "$soal_file"

        if [[ ! -s "$soal_file" ]]; then
            echo -e "${RED}Tidak dapat menemukan soal. Cek cookie atau URL.${NC}"
            read -p "Tekan Enter..."
            continue
        fi

        total=$(wc -l < "$soal_file")
        echo -e "${GREEN}Ditemukan $total soal.${NC}"

        local regenerate=true
        while [[ "$regenerate" == true ]]; do
            declare -A answers
            declare -A soal_texts
            if generate_all_answers "$soal_file" answers soal_texts; then
                show_all_answers answers
                echo -e "${YELLOW}Apakah semua jawaban sudah sesuai? (y/n)${NC}"
                read -r confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    if submit_answers "$pertemuan" "$mk" "$kelas" answers; then
                        echo -e "${YELLOW}Buat laporan Word? (y/n): ${NC}"
                        read -r buat_laporan
                        if [[ "$buat_laporan" == "y" || "$buat_laporan" == "Y" ]]; then
                            echo -e "${YELLOW}Masukkan data diri untuk laporan:${NC}"
                            echo -n "Nama lengkap: "; read -r nama
                            echo -n "NPM: "; read -r npm
                            if [[ -n "$nama" && -n "$npm" ]]; then
                                generate_docx_report answers soal_texts "$nama" "$npm" "$mk" "$kelas" "$pertemuan"
                            else
                                echo -e "${RED}Nama dan NPM wajib diisi. Laporan dibatalkan.${NC}"
                            fi
                        fi
                    fi
                    regenerate=false
                else
                    echo -e "${YELLOW}Meregenerate semua jawaban...${NC}"
                    unset answers
                    unset soal_texts
                    regenerate=true
                fi
            else
                echo -e "${RED}Gagal generate jawaban. Ulangi? (y/n)${NC}"
                read -r retry
                [[ "$retry" != "y" && "$retry" != "Y" ]] && break
                regenerate=true
            fi
        done

        echo -e "${YELLOW}Selesai. Tekan Enter untuk kembali ke menu utama${NC}"
        read -r
    done
}

# ========== FUNGSI TAMPIL HASIL UJIAN (TAMBAHAN BARU) ==========

# Ekstrak data hasil dari HTML response
extract_result_data() {
    local html_file="$1"
    local nilai=""
    local total=""
    local dikerjakan=""
    local benar=""
    
    # Gunakan perl untuk parsing yang lebih stabil
    perl -e '
        local $/;
        open(my $fh, "<", $ARGV[0]) or die;
        my $html = <$fh>;
        close($fh);
        
        # Cari nilai: <div class="nilai ...">96.1</div>
        if ($html =~ /<div\s+class="[^"]*nilai[^"]*"[^>]*>([0-9.]+)<\/div>/i) {
            print "nilai=$1\n";
        }
        # Cari Total Soal: biasanya "Total Soal: 77" atau "Total: 77"
        if ($html =~ /Total\s+Soal:\s*([0-9]+)/i) {
            print "total=$1\n";
        } elsif ($html =~ /Total:\s*([0-9]+)/i) {
            print "total=$1\n";
        }
        # Cari Dikerjakan
        if ($html =~ /Dikerjakan:\s*([0-9]+)/i) {
            print "dikerjakan=$1\n";
        }
        # Cari Benar
        if ($html =~ /Benar:\s*([0-9]+)/i) {
            print "benar=$1\n";
        }
    ' "$html_file" > "$TEMP_DIR/result_data.txt"
    
    source "$TEMP_DIR/result_data.txt"
    echo "$nilai|$total|$dikerjakan|$benar"
}

# Tampilkan kotak hasil seperti HTML
show_result_box() {
    local nilai="$1"
    local total="$2"
    local dikerjakan="$3"
    local benar="$4"
    
    clear_screen
    show_banner
    
    local border="${GREEN}========================================${NC}"
    local box_top="${GREEN}+--------------------------------------+${NC}"
    local box_bottom="${GREEN}+--------------------------------------+${NC}"
    
    echo -e "$border"
    echo -e "${YELLOW}            HASIL UJIAN${NC}"
    echo -e "$border"
    echo -e "${box_top}"
    printf "|  ${BLUE}Nilai Akhir${NC}            :  ${GREEN}%s${NC}\n" "$nilai"
    printf "|  ${BLUE}Total Soal${NC}             :  %s\n" "$total"
    printf "|  ${BLUE}Dikerjakan${NC}             :  %s\n" "$dikerjakan"
    printf "|  ${BLUE}Benar${NC}                  :  %s\n" "$benar"
    echo -e "${box_bottom}"
    
    # Jika nilai tinggi, kasih warna
    if (( $(echo "$nilai >= 85" | bc -l 2>/dev/null) )); then
        echo -e "${GREEN}✨ Selamat! Anda lulus dengan sangat baik. ✨${NC}"
    elif (( $(echo "$nilai >= 70" | bc -l 2>/dev/null) )); then
        echo -e "${YELLOW}👍 Cukup baik, tingkatkan lagi. 👍${NC}"
    else
        echo -e "${RED}💪 Perlu belajar lebih giat. 💪${NC}"
    fi
    echo -e "$border"
}

# ========== PILIHAN GANDA (DIPERBAIKI) ==========

# Parsing soal pilihan ganda - versi robust dengan debugging
parse_pilgan() {
    local html_file="$1"
    local output_file="$2"
    > "$output_file"
    
    # Perl dengan pendekatan parsing blok per blok
    perl -e '
        use strict;
        use warnings;
        my $html_file = $ARGV[0];
        my $out_file = $ARGV[1];
        open(my $fh, "<", $html_file) or die "Cannot open $html_file: $!";
        my $html = do { local $/; <$fh> };
        close($fh);
        
        # Cari semua <div class="soal-box"> ... </div>
        my @soal_blocks;
        while ($html =~ /<div class="soal-box">(.*?)<\/div>\s*(?=<div class="soal-box">|<\/form>|$)/sg) {
            push @soal_blocks, $1;
        }
        
        my $soal_count = 0;
        open(my $out, ">", $out_file) or die "Cannot open $out_file: $!";
        
        foreach my $block (@soal_blocks) {
            # Ekstrak ID soal
            my ($id) = $block =~ /name="jawaban\[(\d+)\]/;
            next unless $id;
            
            # Ekstrak teks soal dari <h6>
            my ($soal_text) = $block =~ /<h6>([\s\S]*?)<\/h6>/i;
            next unless $soal_text;
            $soal_text =~ s/<[^>]+>//g;
            $soal_text =~ s/\s+/ /g;
            $soal_text =~ s/^\s+|\s+$//g;
            
            # Ekstrak semua opsi dari .opsi-box
            my %opsi;
            my @opsi_boxes = $block =~ /<div class="[^"]*opsi-box[^"]*"[^>]*>([\s\S]*?)<\/div>\s*(?=<div class="|$)/g;
            foreach my $obox (@opsi_boxes) {
                my ($val) = $obox =~ /value="([A-E])"/;
                next unless $val;
                my ($label) = $obox =~ /<label[^>]*>([\s\S]*?)<\/label>/i;
                next unless $label;
                $label =~ s/<[^>]+>//g;
                $label =~ s/\s+/ /g;
                $label =~ s/^\s+|\s+$//g;
                $label =~ s/&nbsp;/ /g;
                $opsi{$val} = $label if $label ne "";
            }
            
            my $opt_count = scalar keys %opsi;
            if ($opt_count < 2) {
                warn "Soal ID $id hanya memiliki $opt_count opsi, dilewati.\n";
                next;
            }
            
            # Output: ID|Soal|A:teks|B:teks|C:teks|D:teks|E:teks
            my @out = ($id, $soal_text);
            for my $l (qw(A B C D E)) {
                my $txt = $opsi{$l} // "";
                if ($txt ne "") {
                    push @out, "$l:$txt";
                }
            }
            print $out join("|", @out) . "\n";
            $soal_count++;
        }
        close($out);
        print STDERR "[parse] Total soal terdeteksi: $soal_count\n";
    ' "$html_file" "$output_file"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error saat parsing HTML pilihan ganda.${NC}" >&2
        return 1
    fi
    
    local total=$(wc -l < "$output_file" 2>/dev/null || echo "0")
    echo -e "${GREEN}[parse] Ditemukan $total soal pilihan ganda.${NC}" >&2
    return 0
}

# Generate jawaban untuk satu soal pilihan ganda (dengan prompt yang lebih baik)
generate_pilgan_answer() {
    local soal="$1"
    shift
    local options=("$@")
    
    # Bangun teks opsi yang jelas
    local options_text=""
    for opt in "${options[@]}"; do
        options_text="${options_text}\n${opt}"
    done
    
    if [[ $DEBUG -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG] Soal yang dikirim ke AI:${NC}" >&2
        echo -e "${BLUE}$soal${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Opsi yang dikirim (${#options[@]} opsi):${NC}" >&2
        for opt in "${options[@]}"; do
            echo -e "${BLUE}  $opt${NC}" >&2
        done
    fi
    
    # Pastikan jumlah opsi lengkap (5) – jika kurang, beri peringatan
    if [[ ${#options[@]} -lt 5 ]]; then
        echo -e "${YELLOW}[WARN] Opsi tidak lengkap (${#options[@]}/5). Tetap diproses.${NC}" >&2
    fi
    
    local system_prompt="Anda adalah ahli dalam Pemrograman Berorientasi Objek (PBO/OOP). Tugas Anda menjawab soal pilihan ganda dengan tepat. Berikan hanya HURUF (A, B, C, D, atau E) tanpa karakter lain, tanpa titik, tanpa penjelasan. Pastikan jawaban benar secara akademis."
    
    local user_prompt="SOAL PILIHAN GANDA (OOP):\n\n$soal\n\nPILIHAN JAWABAN:\n$options_text\n\nPilih satu jawaban yang paling benar. Jawab hanya dengan huruf kapital A, B, C, D, atau E. Jangan tambahkan apapun."
    
    if [[ $DEBUG -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG] User prompt (first 500 chars):${NC}" >&2
        echo "$user_prompt" | head -c 10000 >&2
        echo "" >&2
    fi
    
    local response=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$OLLAMA_MODEL\",
            \"system\": $(printf '%s' "$system_prompt" | jq -R -s -c .),
            \"prompt\": $(printf '%s' "$user_prompt" | jq -R -s -c .),
            \"stream\": false,
            \"options\": {\"num_predict\": 10, \"temperature\": 0.2}
        }")
    
    local raw_answer=$(echo "$response" | jq -r '.response // empty' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    local answer=""
    
    if [[ "$raw_answer" =~ ^[A-E]$ ]]; then
        answer="$raw_answer"
    elif [[ "$raw_answer" =~ [A-E] ]]; then
        answer="${BASH_REMATCH[0]}"
    else
        echo -e "${RED}AI gagal memberikan jawaban valid untuk soal: $soal${NC}" >&2
        return 1
    fi
    
    if [[ $DEBUG -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG] Jawaban mentah dari AI: '$(echo "$response" | jq -r '.response // empty')'${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Jawaban setelah diproses: '$answer'${NC}" >&2
    fi
    
    echo "$answer"
    return 0
}

generate_all_pilgan_answers() {
    local soal_file="$1"
    local -n answers_ref=$2
    local -n soal_texts_ref=$3
    local -n options_ref=$4
    
    local total=$(wc -l < "$soal_file")
    echo -e "${YELLOW}Mulai generate jawaban pilihan ganda untuk $total soal (menggunakan AI)...${NC}"
    local count=0
    
    while IFS='|' read -r id soal opsi_a opsi_b opsi_c opsi_d opsi_e; do
        ((count++))
        if [[ -z "$id" || -z "$soal" ]]; then
            echo -e "${RED}Baris tidak valid: ID atau soal kosong${NC}" >&2
            continue
        fi
        
        local opsi_array=()
        for opt in "$opsi_a" "$opsi_b" "$opsi_c" "$opsi_d" "$opsi_e"; do
            if [[ -n "$opt" ]]; then
                opsi_array+=("$opt")
            fi
        done
        
        # Jika opsi kurang dari 2, skip
        if [[ ${#opsi_array[@]} -lt 2 ]]; then
            echo -e "${RED}Soal ID $id hanya memiliki ${#opsi_array[@]} opsi, dilewati.${NC}" >&2
            continue
        fi
        
        echo -e "\n${BLUE}========================================${NC}"
        echo -e "${YELLOW}[$count/$total] Soal ID $id:${NC}"
        echo -e "${GREEN}$soal${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        echo -e "${YELLOW}Menentukan jawaban dengan AI...${NC}"
        
        answer=$(generate_pilgan_answer "$soal" "${opsi_array[@]}")
        if [[ $? -eq 0 && -n "$answer" ]]; then
            answers_ref["$id"]="$answer"
            soal_texts_ref["$id"]="$soal"
            options_ref["$id"]=$(printf "%s|" "${opsi_array[@]}" | sed 's/|$//')
            echo -e "${GREEN}--- Jawaban AI: ${answer} ---${NC}"
            for opt in "${opsi_array[@]}"; do
                if [[ "$opt" == "${answer}:"* ]]; then
                    echo -e "${GREEN}✓ $opt${NC}"
                fi
            done
            echo -e "${BLUE}========================================${NC}\n"
        else
            echo -e "${RED}✗ Gagal generate jawaban untuk ID $id.${NC}"
            return 1
        fi
    done < "$soal_file"
    return 0
}

show_pilgan_detail() {
    local -n answers_ref=$1
    local -n soal_texts_ref=$2
    local -n options_ref=$3
    
    echo -e "${YELLOW}========== RINGKASAN JAWABAN PILIHAN GANDA ==========${NC}"
    local nomor=1
    local sorted_ids=($(for id in "${!answers_ref[@]}"; do echo "$id"; done | sort -n))
    for id in "${sorted_ids[@]}"; do
        echo -e "\n${BLUE}[$nomor] Soal ID: $id${NC}"
        echo -e "${GREEN}Soal: ${soal_texts_ref[$id]}${NC}"
        local opts="${options_ref[$id]}"
        IFS='|' read -ra opt_arr <<< "$opts"
        for opt in "${opt_arr[@]}"; do
            echo -e "  ${opt}"
        done
        echo -e "${YELLOW}Jawaban AI: ${answers_ref[$id]}${NC}"
        ((nomor++))
    done
    echo -e "${YELLOW}====================================================${NC}"
}

submit_pilgan() {
    local mk="$1"
    local -n answers_ref=$2
    
    local base_url="https://belajarpandai.com/tes${mk}2526/mahasiswa"
    local submit_url="${base_url}/submit.php"
    local referer_url="${base_url}/ujian.php"
    
    echo -e "${YELLOW}Mengirim jawaban pilihan ganda ke $submit_url ...${NC}"
    
    # Bangun command curl dengan --data-urlencode untuk setiap jawaban
    local curl_cmd="curl -s -L -X POST '$submit_url' \
        -b '$COOKIE' \
        -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
        -H 'Accept-Language: en-US,en;q=0.9' \
        -H 'Cache-Control: max-age=0' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Origin: https://belajarpandai.com' \
        -H 'Referer: $referer_url' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0' \
        -H 'Upgrade-Insecure-Requests: 1' \
        --compressed"
    
    # Tambahkan setiap jawaban sebagai --data-urlencode
    for id in "${!answers_ref[@]}"; do
        curl_cmd="$curl_cmd --data-urlencode 'jawaban[$id]=${answers_ref[$id]}'"
    done
    
    # Simpan command ke file untuk debugging
    local curl_debug_file="$TEMP_DIR/curl_pilgan_submit.sh"
    echo "$curl_cmd" > "$curl_debug_file"
    chmod +x "$curl_debug_file"
    echo -e "${YELLOW}[DEBUG] Curl command disimpan di: $curl_debug_file${NC}"
    
    # Eksekusi curl
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    
    # Simpan response untuk debugging jika gagal
    echo "$response" > "$TEMP_DIR/pilgan_response.txt"
    
    # Cek apakah response mengandung indikasi sukses
    if echo "$response" | grep -qi "nilai\|hasil ujian\|terima kasih\|dashboard.php\|sukses\|berhasil"; then
        echo -e "${GREEN}✓ Jawaban pilihan ganda berhasil dikirim!${NC}"
        return 0
    else
        echo -e "${RED}Gagal mengirim jawaban. Response disimpan di $TEMP_DIR/pilgan_response.txt${NC}"
        echo -e "${YELLOW}Response awal (max 20 baris):${NC}"
        cat "$TEMP_DIR/pilgan_response.txt" | head -n 20
        return 1
    fi
}

menu_pilgan() {
    while true; do
        clear_screen
        show_banner
        echo -e "${BLUE}=== MODE PILIHAN GANDA DENGAN AI ===${NC}"
        echo "Pilih mata kuliah:"
        echo "  1) RPL"
        echo "  2) PBO"
        echo "  3) Kembali"
        read -r choice_mk
        
        case $choice_mk in
            1) mk="rpl";;
            2) mk="pbo";;
            3) return;;
            *) echo "Pilihan salah"; continue;;
        esac
        
        get_cookie
        
        local ujian_url="https://belajarpandai.com/tes${mk}2526/mahasiswa/ujian.php"
        echo -e "${YELLOW}Mengambil soal dari $ujian_url${NC}"
        
        local html_file="$TEMP_DIR/pilgan_soal.html"
        curl -s -b "$COOKIE" "$ujian_url" -o "$html_file"
        
        if [[ ! -s "$html_file" ]]; then
            echo -e "${RED}Gagal mengambil halaman ujian. Cek cookie atau URL.${NC}"
            read -p "Tekan Enter..."
            continue
        fi
        
        echo -e "${YELLOW}Ukuran HTML: $(stat -c%s "$html_file") bytes${NC}"
        
        local soal_file="$TEMP_DIR/pilgan_daftar.txt"
        parse_pilgan "$html_file" "$soal_file"
        
        if [[ ! -s "$soal_file" ]]; then
            echo -e "${RED}Tidak dapat menemukan soal. Cek struktur HTML.${NC}"
            echo -e "${YELLOW}File HTML yang didownload: $html_file (size: $(stat -c%s "$html_file" 2>/dev/null || echo "0") bytes)${NC}"
            echo -e "${YELLOW}Apakah Anda ingin melihat cuplikan HTML? (y/n)${NC}"
            read -r show_html
            if [[ "$show_html" == "y" ]]; then
                head -n 50 "$html_file"
            fi
            read -p "Tekan Enter..."
            continue
        fi
        
        local total=$(wc -l < "$soal_file")
        echo -e "${GREEN}Ditemukan $total soal pilihan ganda.${NC}"
        echo -e "${YELLOW}Apakah Anda ingin melihat hasil parse per soal? (y/n)${NC}"
        read -r show_parse
        if [[ "$show_parse" == "y" ]]; then
            cat "$soal_file"
            echo "----------------------------------------"
            read -p "Tekan Enter untuk melanjutkan..."
        fi
        
        local regenerate=true
        while [[ "$regenerate" == true ]]; do
            declare -A answers
            declare -A soal_texts
            declare -A options
            
            if generate_all_pilgan_answers "$soal_file" answers soal_texts options; then
                show_pilgan_detail answers soal_texts options
                
                echo -e "${YELLOW}Apakah semua jawaban sudah sesuai? (y/n)${NC}"
                read -r confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    echo -e "${YELLOW}Anda yakin ingin mengirim jawaban? (y/n)${NC}"
                    read -r final_confirm
                    if [[ "$final_confirm" == "y" || "$final_confirm" == "Y" ]]; then
                        if submit_pilgan "$mk" answers; then
                            echo -e "${GREEN}Jawaban berhasil dikirim!${NC}"
                            
                            # ===== TAMPILKAN HASIL UJIAN (TAMBAHAN BARU) =====
                            if [[ -f "$TEMP_DIR/pilgan_response.txt" ]]; then
                                echo -e "${YELLOW}Mengambil data hasil ujian...${NC}"
                                result=$(extract_result_data "$TEMP_DIR/pilgan_response.txt")
                                IFS='|' read -r nilai total dikerjakan benar <<< "$result"
                                
                                if [[ -n "$nilai" && -n "$total" ]]; then
                                    show_result_box "$nilai" "$total" "$dikerjakan" "$benar"
                                else
                                    echo -e "${RED}Tidak dapat mengekstrak nilai dari halaman hasil.${NC}"
                                    echo -e "${YELLOW}Cuplikan respons (max 20 baris):${NC}"
                                    head -n 20 "$TEMP_DIR/pilgan_response.txt"
                                fi
                            else
                                echo -e "${RED}File response tidak ditemukan.${NC}"
                            fi
                            # =================================================
                        else
                            echo -e "${RED}Gagal mengirim jawaban. Silakan coba lagi.${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Submit dibatalkan.${NC}"
                    fi
                    regenerate=false
                else
                    echo -e "${YELLOW}Meregenerate semua jawaban...${NC}"
                    unset answers
                    unset soal_texts
                    unset options
                    regenerate=true
                fi
            else
                echo -e "${RED}Gagal generate jawaban. Ulangi? (y/n)${NC}"
                read -r retry
                [[ "$retry" != "y" && "$retry" != "Y" ]] && break
                regenerate=true
            fi
        done
        
        echo -e "${YELLOW}Selesai. Tekan Enter untuk kembali ke menu utama${NC}"
        read -r
    done
}

get_cookie() {
    echo -e "${YELLOW}Masukkan cookie autentikasi:${NC}"
    echo -n "Cookie: "
    read -r COOKIE
    [[ -z "$COOKIE" ]] && { echo -e "${RED}Cookie wajib diisi${NC}"; exit 1; }
    echo -e "${GREEN}Cookie tersimpan${NC}\n"
}

# ===================== MENU UTAMA =====================
main_menu() {
    while true; do
        clear_screen
        show_banner
        echo -e "${BLUE}Pilih mode:${NC}"
        echo "  1) Essay dengan AI (DeepSeek V3.1)"
        echo "  2) Pilihan Ganda dengan AI (dengan debug & konfirmasi detail)"
        echo "  3) Keluar"
        read -r mode
        case $mode in
            1) menu_essay_ai ;;
            2) menu_pilgan ;;
            3) exit 0 ;;
        esac
    done
}

# ===================== START SCRIPT =====================
clear_screen
show_banner
auto_setup_and_signin
main_menu
