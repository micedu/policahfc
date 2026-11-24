#!/bin/bash
# =====================================================================
#  TALLER CALIFICABLE - CONTENEDORES Y EL HARDWARE DEL HOST
#  Comprension de la Arquitectura del Hardware
#  Tecnologia en Sistematizacion de Datos
#
#  Uso:   bash montaje.sh <CODIGO-DE-ESTUDIANTE>
#
#  El script comprueba que esta maquina puede hacer todo lo que el
#  taller exige. Si no termina con "ESCENARIO LISTO", NO empiece:
#  avise al docente.
# =====================================================================
set -u

CODIGO="${1:-}"
if [ -z "$CODIGO" ]; then
  echo "ERROR: falta su codigo de estudiante."
  echo "Uso: bash montaje.sh 1234567"
  exit 1
fi

case "$CODIGO" in
  *[!0-9]*) echo "ERROR: el codigo debe tener solo numeros."; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: no hay docker en esta maquina."
  echo "Abrio el Playground equivocado: necesita el de Ubuntu con Docker."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker esta instalado pero el servicio no responde."
  echo "Espere medio minuto y vuelva a intentarlo."
  exit 1
fi

BASE=/root/taller
mkdir -p "$BASE"

# =====================================================================
#  SEMILLA DERIVADA DEL CODIGO  (identica en verificar.sh)
# =====================================================================
SEM=$(printf '%s' "$CODIGO" | md5sum | tr -dc '0-9' | cut -c1-9)
SEM=$((10#$SEM))

A_OPTS=(0.20 0.25 0.30)
B_OPTS=(0.45 0.50 0.55)
CPU_A=${A_OPTS[$(( SEM % 3 ))]}
CPU_B=${B_OPTS[$(( (SEM / 7) % 3 ))]}
MEM=$(( 48 + 8 * (SEM % 7) ))          # 48 a 96 MB

C_A="cpu-a-$CODIGO"
C_B="cpu-b-$CODIGO"
C_OOM="oom-$CODIGO"
C_SRV="srv-$CODIGO"
IMG="reporte-$CODIGO:v1"
RED="red-$CODIGO"

echo "==================================================="
echo " Preparando el taller para el codigo: $CODIGO"
echo " Toma cerca de un minuto. No interrumpa."
echo "==================================================="

# ---------- limpieza de un intento anterior ----------
docker rm -f "$C_A" "$C_B" "$C_OOM" "$C_SRV" >/dev/null 2>&1
docker rm -f prueba-cpu prueba-oom prueba-srv >/dev/null 2>&1
docker network rm "$RED" prueba-red >/dev/null 2>&1
docker rmi -f "$IMG" >/dev/null 2>&1
rm -rf "$BASE/reporte"

# =====================================================================
#  DESCARGA PREVIA DE IMAGENES
# =====================================================================
echo "[1] Descargando las imagenes que va a necesitar..."
IMGS_OK=1
for I in alpine busybox nginx:alpine; do
  docker pull "$I" >/dev/null 2>&1 || IMGS_OK=0
done

# =====================================================================
#  COMPROBACIONES DE LA MAQUINA
# =====================================================================
echo "[2] Comprobando que esta maquina aplica limites de procesador..."
docker run -d --name prueba-cpu --cpus="0.5" busybox \
  sh -c 'while true; do :; done' >/dev/null 2>&1
sleep 6
USO=$(docker stats --no-stream --format '{{.CPUPerc}}' prueba-cpu 2>/dev/null | tr -d '%')
docker rm -f prueba-cpu >/dev/null 2>&1

echo "[3] Comprobando que esta maquina mata por falta de memoria..."
docker run --name prueba-oom --memory="64m" --tmpfs /ram:size=512m alpine \
  sh -c 'dd if=/dev/zero of=/ram/relleno bs=1M count=300' >/dev/null 2>&1
OOM=$(docker inspect prueba-oom --format '{{.State.OOMKilled}} {{.State.ExitCode}}' 2>/dev/null)
docker rm -f prueba-oom >/dev/null 2>&1

echo "[4] Comprobando la red entre contenedores..."
docker network create prueba-red >/dev/null 2>&1
docker run -d --name prueba-srv --network prueba-red nginx:alpine >/dev/null 2>&1
sleep 4
REDOK=$(docker run --rm --network prueba-red alpine \
        getent hosts prueba-srv 2>/dev/null | wc -l)
docker rm -f prueba-srv >/dev/null 2>&1
docker network rm prueba-red >/dev/null 2>&1

# =====================================================================
#  REGISTRO Y HOJA DE REQUISITOS
# =====================================================================
printf '%s' "$CODIGO" > "$BASE/.codigo"
date +%s > "$BASE/.inicio"
chmod 600 "$BASE/.codigo" "$BASE/.inicio" 2>/dev/null

cat > "$BASE/requisitos.txt" <<EOF
=====================================================================
 REQUISITOS DE SU ENTREGA  -  codigo $CODIGO
 Estos valores son unicos para usted. Lealos aqui, no los adivine.
=====================================================================

 REGLA DE FORMA
 Respete los nombres exactos. La verificacion los busca asi, letra
 por letra. Si les cambia el nombre, no los encuentra.

---------------------------------------------------------------------
 OBJETIVO 1  -  DOS CONTENEDORES COMPARTIENDO EL UNICO NUCLEO
---------------------------------------------------------------------
 Deje corriendo al mismo tiempo dos contenedores que gasten
 procesador sin parar, cada uno con su propio techo:

     nombre: $C_A       limite: --cpus="$CPU_A"
     nombre: $C_B       limite: --cpus="$CPU_B"

 Los dos deben estar en ejecucion y consumiendo de verdad cuando
 ejecute la verificacion.

---------------------------------------------------------------------
 OBJETIVO 2  -  MUERTE POR FALTA DE MEMORIA
---------------------------------------------------------------------
 Provoque que el sistema operativo mate un contenedor por superar su
 techo de memoria:

     nombre: $C_OOM
     limite: --memory="${MEM}m"

 Al terminar, ese contenedor debe quedar registrado como muerto por
 falta de memoria. No lo borre: la verificacion necesita su rastro.

---------------------------------------------------------------------
 OBJETIVO 3  -  UNA IMAGEN PROPIA QUE REPORTE EL HARDWARE
---------------------------------------------------------------------
 Construya con un Dockerfile una imagen llamada exactamente:

     $IMG

 Al ejecutarla debe imprimir estas cuatro lineas, con estas mismas
 etiquetas y los valores reales que lea de la maquina:

     Procesadores: <numero>
     Arquitectura: <arquitectura>
     Kernel: <version del nucleo>
     Memoria total MB: <numero>

---------------------------------------------------------------------
 OBJETIVO 4  -  UNA RED VIRTUAL CON NOMBRES
---------------------------------------------------------------------
 Cree una red propia y conecte a ella un servidor web:

     red:    $RED
     nombre: $C_SRV      imagen: nginx:alpine

 Desde otro contenedor conectado a esa misma red, el nombre
 $C_SRV debe resolverse y responder.

=====================================================================
 Cuando termine:   bash verificar.sh
=====================================================================
EOF

# =====================================================================
#  INFORME DEL MONTAJE
# =====================================================================
echo
echo "Comprobando el escenario..."
A=0; B=0; C=0; D=0
DET_A="no se pudieron descargar las imagenes"
DET_B="no se pudo medir el limite de procesador"
DET_C="la maquina no mato el contenedor por falta de memoria"
DET_D="los contenedores no se resuelven por nombre"

if [ "$IMGS_OK" -eq 1 ]; then
  A=1; DET_A="alpine, busybox y nginx:alpine listas en esta maquina"
fi

if [ -n "${USO:-}" ]; then
  ENTERO=${USO%%.*}
  if [ "${ENTERO:-0}" -ge 30 ] && [ "${ENTERO:-0}" -le 75 ]; then
    B=1; DET_B="un contenedor limitado a 0.5 CPU consumio ${USO} %"
  else
    DET_B="el limite de 0.5 CPU dio ${USO} %: no se esta aplicando bien"
  fi
fi

if [ "${OOM:-}" = "true 137" ]; then
  C=1; DET_C="OOMKilled=true y salida 137, como debe ser"
else
  DET_C="se esperaba 'true 137' y se obtuvo '${OOM:-sin lectura}'"
fi

if [ "${REDOK:-0}" -ge 1 ]; then
  D=1; DET_D="un contenedor resolvio a otro por su nombre"
fi

TOTAL=$(( A + B + C + D ))

echo
echo "==================================================="
printf " 1  Imagenes ............. %s  (%s)\n" "$([ $A -eq 1 ] && echo 'LISTO' || echo 'FALLO')" "$DET_A"
printf " 2  Limite de CPU ........ %s  (%s)\n" "$([ $B -eq 1 ] && echo 'LISTO' || echo 'FALLO')" "$DET_B"
printf " 3  Limite de memoria .... %s  (%s)\n" "$([ $C -eq 1 ] && echo 'LISTO' || echo 'FALLO')" "$DET_C"
printf " 4  Red entre contenedores %s  (%s)\n" "$([ $D -eq 1 ] && echo 'LISTO' || echo 'FALLO')" "$DET_D"
echo "==================================================="

if [ "$TOTAL" -ne 4 ]; then
  echo
  echo " ATENCION: solo $TOTAL de 4 comprobaciones pasaron."
  echo " NO empiece el taller. Avise al docente ahora mismo e"
  echo " indiquele cual linea dice FALLO y que mensaje aparece."
  echo
  exit 1
fi

echo
echo " ESCENARIO LISTO  -  codigo $CODIGO"
echo
echo " Esta maquina puede hacer todo lo que el taller le va a pedir."
echo " Nada esta construido todavia: eso le toca a usted."
echo
echo " Sus requisitos quedaron en:  $BASE/requisitos.txt"
echo
echo " Lealos ahora:   cat $BASE/requisitos.txt"
echo
echo " Cuando termine, ejecute:   bash verificar.sh"
echo
