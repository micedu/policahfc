#!/bin/bash
# =====================================================================
#  TALLER CALIFICABLE - CONTENEDORES Y EL HARDWARE DEL HOST
#  VERIFICACION
#  Uso:   bash verificar.sh
#
#  No borra nada de lo que usted construyo. Puede ejecutarla las
#  veces que quiera mientras le quede tiempo.
# =====================================================================
set -u

BASE=/root/taller
SAL="arq2026tsd"

if [ ! -f "$BASE/.codigo" ]; then
  echo "ERROR: no encuentro el taller. Ejecute primero el montaje."
  exit 1
fi

CODIGO=$(cat "$BASE/.codigo")
INICIO=$(cat "$BASE/.inicio")
MIN=$(( ( $(date +%s) - INICIO ) / 60 ))

# ---------- semilla, identica a montaje.sh ----------
SEM=$(printf '%s' "$CODIGO" | md5sum | tr -dc '0-9' | cut -c1-9)
SEM=$((10#$SEM))
A_OPTS=(0.20 0.25 0.30)
B_OPTS=(0.45 0.50 0.55)
CPU_A=${A_OPTS[$(( SEM % 3 ))]}
CPU_B=${B_OPTS[$(( (SEM / 7) % 3 ))]}
MEM=$(( 48 + 8 * (SEM % 7) ))

C_A="cpu-a-$CODIGO"
C_B="cpu-b-$CODIGO"
C_OOM="oom-$CODIGO"
C_SRV="srv-$CODIGO"
IMG="reporte-$CODIGO:v1"
RED="red-$CODIGO"

NANO_A=$(awk "BEGIN{printf \"%d\", $CPU_A*1000000000}")
NANO_B=$(awk "BEGIN{printf \"%d\", $CPU_B*1000000000}")
BYTES=$(( MEM * 1024 * 1024 ))

insp() { docker inspect "$1" --format "$2" 2>/dev/null; }

echo
echo "Verificando..."

R1=0; R2=0; R3=0; R4=0
D1="-"; D2="-"; D3="-"; D4="-"

# =====================================================================
#  1. DOS CONTENEDORES CON LIMITES DISTINTOS, QUEMANDO A LA VEZ
# =====================================================================
EST_A=$(insp "$C_A" '{{.State.Running}}')
EST_B=$(insp "$C_B" '{{.State.Running}}')
LIM_A=$(insp "$C_A" '{{.HostConfig.NanoCpus}}')
LIM_B=$(insp "$C_B" '{{.HostConfig.NanoCpus}}')

if [ "${EST_A:-}" != "true" ] || [ "${EST_B:-}" != "true" ]; then
  D1="faltan contenedores en ejecucion: $C_A=${EST_A:-no existe}, $C_B=${EST_B:-no existe}"
elif [ "${LIM_A:-0}" != "$NANO_A" ] || [ "${LIM_B:-0}" != "$NANO_B" ]; then
  D1="los limites no son los exigidos (se pidio $CPU_A y $CPU_B)"
else
  U_A=$(docker stats --no-stream --format '{{.CPUPerc}}' "$C_A" 2>/dev/null | tr -d '%')
  U_B=$(docker stats --no-stream --format '{{.CPUPerc}}' "$C_B" 2>/dev/null | tr -d '%')
  VIVO=$(awk "BEGIN{print (${U_A:-0} > 5 && ${U_B:-0} > 5) ? 1 : 0}")
  if [ "$VIVO" = "1" ]; then
    R1=1; D1="ambos corriendo con sus limites; consumo medido ${U_A}% y ${U_B}%"
  else
    D1="los limites son correctos pero no estan gastando procesador (${U_A:-0}% y ${U_B:-0}%)"
  fi
fi

# =====================================================================
#  2. MUERTE POR FALTA DE MEMORIA
# =====================================================================
if ! docker inspect "$C_OOM" >/dev/null 2>&1; then
  D2="no existe el contenedor $C_OOM"
else
  OOMK=$(insp "$C_OOM" '{{.State.OOMKilled}}')
  SALIDA=$(insp "$C_OOM" '{{.State.ExitCode}}')
  LIM_M=$(insp "$C_OOM" '{{.HostConfig.Memory}}')
  if [ "${LIM_M:-0}" != "$BYTES" ]; then
    D2="el limite de memoria no es el exigido (se pidio ${MEM}m)"
  elif [ "${OOMK:-}" = "true" ] && [ "${SALIDA:-}" = "137" ]; then
    R2=1; D2="muerto por falta de memoria con techo de ${MEM} MB, salida 137"
  else
    D2="limite correcto, pero OOMKilled=${OOMK:-?} y salida=${SALIDA:-?}"
  fi
fi

# =====================================================================
#  3. IMAGEN PROPIA QUE REPORTA EL HARDWARE
# =====================================================================
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  D3="no existe la imagen $IMG"
else
  SALI=$(docker run --rm "$IMG" 2>/dev/null)
  FALTAN=""
  for E in "Procesadores:" "Arquitectura:" "Kernel:" "Memoria total MB:"; do
    echo "$SALI" | grep -q "$E" || FALTAN="$FALTAN $E"
  done
  if [ -n "$FALTAN" ]; then
    D3="la imagen corre pero le faltan estas lineas:$FALTAN"
  elif ! echo "$SALI" | grep -q "$(uname -r)"; then
    D3="la linea Kernel no coincide con el nucleo real de esta maquina"
  else
    R3=1; D3="la imagen existe y reporta los cuatro datos del hardware"
  fi
fi

# =====================================================================
#  4. RED VIRTUAL CON RESOLUCION POR NOMBRE
# =====================================================================
if ! docker network inspect "$RED" >/dev/null 2>&1; then
  D4="no existe la red $RED"
elif [ "$(insp "$C_SRV" '{{.State.Running}}')" != "true" ]; then
  D4="el contenedor $C_SRV no esta en ejecucion"
else
  EN_RED=$(docker network inspect "$RED" \
           --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -c "$C_SRV")
  if [ "${EN_RED:-0}" -lt 1 ]; then
    D4="$C_SRV existe pero no esta conectado a la red $RED"
  else
    RES=$(docker run --rm --network "$RED" alpine \
          getent hosts "$C_SRV" 2>/dev/null | wc -l)
    if [ "${RES:-0}" -ge 1 ]; then
      R4=1; D4="otro contenedor resolvio $C_SRV por su nombre dentro de $RED"
    else
      D4="el nombre $C_SRV no se resuelve desde la red $RED"
    fi
  fi
fi

# =====================================================================
#  INFORME
# =====================================================================
TOTAL=$(( R1 + R2 + R3 + R4 ))
FIRMA=$(printf '%s' "$CODIGO$R1$R2$R3$R4$MIN$SAL" | md5sum | cut -c1-8)
FINAL="AH-$CODIGO-$R1$R2$R3$R4-${MIN}m-$FIRMA"

echo
echo "==================================================="
echo " VERIFICACION DEL TALLER  -  codigo $CODIGO"
echo "==================================================="
echo
printf " 1  Reparto del procesador .. %s\n" "$([ $R1 -eq 1 ] && echo 'CUMPLIDO ' || echo 'pendiente')"
printf "      %s\n" "$D1"
printf " 2  Limite de memoria ....... %s\n" "$([ $R2 -eq 1 ] && echo 'CUMPLIDO ' || echo 'pendiente')"
printf "      %s\n" "$D2"
printf " 3  Imagen propia ........... %s\n" "$([ $R3 -eq 1 ] && echo 'CUMPLIDO ' || echo 'pendiente')"
printf "      %s\n" "$D3"
printf " 4  Red virtual ............. %s\n" "$([ $R4 -eq 1 ] && echo 'CUMPLIDO ' || echo 'pendiente')"
printf "      %s\n" "$D4"
echo
printf " Objetivos alcanzados: %s de 4\n" "$TOTAL"
printf " Tiempo transcurrido desde el montaje: %s minutos\n" "$MIN"
echo
echo " Las mediciones del hardware no se verifican aqui:"
echo " se evaluan en las tablas de su informe."
echo
echo "---------------------------------------------------"
echo " COPIE ESTE CODIGO EN SU INFORME:"
echo
echo "   $FINAL"
echo
echo "---------------------------------------------------"
echo
